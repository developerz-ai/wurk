# frozen_string_literal: true

require_relative '../component'
require_relative '../keys'
require_relative '../middleware/poison_pill'

module Wurk
  class Fetcher
    # Orphan reclamation for the reliable fetcher (Pro super_fetch §3.2).
    #
    # The Reliable fetcher moves each job from a public queue into a
    # per-process private list (`queue:<public>|<host>|<pid>|<idx>`) and
    # leaves it there until the Processor ACKs. A SIGKILLed or crashed
    # worker therefore strands its in-flight jobs in private lists that
    # nobody will ever ACK. The Reaper is the recovery half: it periodically
    # scans for private lists whose owning process is gone and atomically
    # moves their jobs back to the public queue so a live worker re-runs them.
    #
    # Liveness is decided per owner:
    #   * same host — the OS is authoritative: `Process.kill(0, pid)`. This
    #     is instant and ignores a stale `processes` SET entry whose 60s TTL
    #     hasn't lapsed yet, so a `kill -9`ed sibling is reclaimed the moment
    #     the supervisor reaps it rather than 60s later. (Pid reuse by an
    #     unrelated local process is the one blind spot — the supervisor
    #     respawns with a fresh pid, so it does not arise in practice.)
    #   * other host — we cannot ping the pid, so we trust the heartbeat:
    #     the owner is alive iff some live `processes` member (one whose
    #     `info` hash still exists) shares its `host:pid`. Cross-host reclaim
    #     therefore waits out the 60s heartbeat TTL, exactly as the spec says.
    #
    # Re-pushed jobs run through Wurk::Middleware::PoisonPill, which caps a
    # job at RECOVERY_THRESHOLD recoveries within 72h: past the cap the job
    # is killed into the dead set instead of re-queued, so a job that crashes
    # its worker every time can't loop forever.
    #
    # SCANs are scoped to the public queues this process serves and gated by
    # a cluster-wide `SET NX EX` lock, so across a fleet only one process
    # sweeps per interval ("1/min within process group" in the spec) and the
    # keyspace touched is bounded to known queues.
    #
    # Spec: docs/target/sidekiq-pro.md §3.2.
    class Reaper
      include Component

      # Sweep cadence in seconds; also the cluster-lock TTL so exactly one
      # process sweeps per interval. 60s matches the heartbeat TTL — the
      # floor below which cross-host orphans can't be detected anyway.
      DEFAULT_INTERVAL = 60

      LOCK_KEY = 'super_fetch:reaper'
      SCAN_COUNT = 100
      THREAD_NAME = 'wurk-reaper'

      attr_reader :interval

      def initialize(config, interval: DEFAULT_INTERVAL, lock_key: LOCK_KEY)
        @config = config
        @interval = interval
        @lock_key = lock_key
        @thread = nil
        @done = false
        @mutex = ::Mutex.new
        @sleeper = ::ConditionVariable.new
      end

      # Spawns the sweep loop. Idempotent. The loop waits one interval before
      # its first sweep so booting processes don't dogpile Redis and so an
      # un-stopped launcher in a unit test never touches the keyspace.
      def start
        @mutex.synchronize do
          return @thread if @thread

          @done = false
          @thread = spawn_loop_thread
        end
        @thread
      end

      def stop
        @mutex.synchronize do
          @done = true
          @sleeper.signal
        end
        @thread&.join
        @thread = nil
      end

      def running?
        !@thread.nil? && @thread.alive?
      end

      # One cluster-gated sweep: a no-op (returns 0) unless this process wins
      # the interval's lock. Used by the loop.
      def reap
        return 0 unless acquire_lock?

        reclaim!
      end

      # One unguarded sweep over every served queue. Returns the number of
      # jobs reclaimed (re-queued or killed). Public so boot paths and tests
      # can drive a deterministic pass without the cluster lock.
      def reclaim!
        prefixes = live_process_prefixes
        served_queues.sum { |public_q| reclaim_queue(public_q, prefixes) }
      end

      private

      # Union of `queue:<name>` keys across every capsule this process serves.
      # Scoping the scan to these keeps the keyspace we touch bounded and lets
      # parallel test namespaces stay isolated.
      def served_queues
        @config.capsules.each_value
               .flat_map(&:queues)
               .uniq
               .map { |name| Keys.queue(name) }
      end

      # SCAN for this public queue's private lists, reclaim the orphaned ones.
      def reclaim_queue(public_q, prefixes)
        reclaimed = 0
        each_private_list(public_q) do |key, host, pid|
          next if owner_alive?(host, pid, prefixes)

          reclaimed += drain(key, public_q)
        end
        reclaimed
      end

      # Yields [private_list_key, host, pid] for each private list of
      # `public_q`. MATCH `<public_q>|*` matches only this queue's private
      # lists (public queue keys carry no `|`).
      def each_private_list(public_q)
        cursor = '0'
        loop do
          cursor, keys = redis { |c| c.call('SCAN', cursor, 'MATCH', "#{public_q}|*", 'COUNT', SCAN_COUNT) }
          keys.each do |key|
            host, pid = parse_owner(public_q, key)
            yield key, host, pid if pid
          end
          break if cursor == '0'
        end
      end

      # `<public_q>|<host>|<pid>|<idx>` → [host, pid] (pid as Integer), or
      # [nil, nil] when the suffix isn't a well-formed `host|pid|idx` triple.
      # Splitting the suffix off the known public-queue prefix tolerates a
      # `|` inside the queue name itself.
      def parse_owner(public_q, key)
        suffix = key.delete_prefix("#{public_q}|")
        return [nil, nil] if suffix == key

        host, pid, idx = suffix.split('|')
        return [nil, nil] unless host && integer?(pid) && integer?(idx)

        [host, pid.to_i]
      end

      def integer?(str)
        str.is_a?(String) && str.match?(/\A\d+\z/)
      end

      def owner_alive?(host, pid, prefixes)
        return local_pid_alive?(pid) if host == hostname

        prefixes.include?("#{host}:#{pid}")
      end

      def local_pid_alive?(pid)
        ::Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # `host:pid` of every live process — a member of `processes` whose
      # `info` hash still exists. A bare SET membership isn't enough: the
      # member lingers after its 60s hash TTL until ProcessSet#cleanup prunes
      # it, and we must treat that window as dead for cross-host reclaim.
      def live_process_prefixes
        redis do |conn|
          members = conn.call('SMEMBERS', Keys::PROCESSES)
          next ::Set.new if members.empty?

          infos = conn.pipelined { |pipe| members.each { |m| pipe.call('HGET', m, 'info') } }
          members.zip(infos).each_with_object(::Set.new) do |(member, info), set|
            set << host_pid(member) if info
          end
        end
      end

      # identity is `<host>:<pid>:<nonce>`; the owner prefix is `<host>:<pid>`.
      def host_pid(identity)
        identity.split(':')[0..1].join(':')
      end

      # Drain one orphaned private list back to its public queue. Each job is
      # moved with an atomic LMOVE (private tail → public tail) BEFORE the
      # poison check, so a crash mid-drain leaves the job safely in the public
      # queue (at-least-once), never lost. Poison jobs are killed to the dead
      # set by PoisonPill.track! and then LREM'd out of the public queue.
      def drain(private_list, public_q)
        queue_name = public_q.delete_prefix(Keys::QUEUE_PREFIX)
        count = 0
        loop do
          job = redis { |c| c.call('LMOVE', private_list, public_q, 'RIGHT', 'RIGHT') }
          break unless job

          count += 1
          poison_off(public_q, job, queue_name)
        end
        count
      rescue StandardError => e
        handle_exception(e, context: THREAD_NAME)
        count
      end

      def poison_off(public_q, job, queue_name)
        return unless Middleware::PoisonPill.track!(job, queue: queue_name, config: @config) == :poison

        # track! already ZADDed the payload to the dead set; pull the copy we
        # just LMOVE'd onto the public tail so it isn't also re-run.
        redis { |c| c.call('LREM', public_q, -1, job) }
      end

      def acquire_lock?
        redis { |c| c.call('SET', @lock_key, '1', 'NX', 'EX', @interval) } == 'OK'
      end

      def spawn_loop_thread
        t = Thread.new { run_loop }
        t.name = THREAD_NAME
        t.report_on_exception = false
        t
      end

      def run_loop
        until done?
          wait_next
          break if done?

          tick_once
        end
      end

      def tick_once
        reap
      rescue StandardError => e
        handle_exception(e, context: THREAD_NAME) if @config.respond_to?(:handle_exception)
      end

      def wait_next
        @mutex.synchronize { @sleeper.wait(@mutex, @interval) unless @done }
      end

      def done?
        @mutex.synchronize { @done }
      end
    end
  end
end
