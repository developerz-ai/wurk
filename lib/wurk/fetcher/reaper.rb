# frozen_string_literal: true

require_relative '../component'
require_relative '../keys'
require_relative '../middleware/poison_pill'
require_relative '../timer_loop'

module Wurk
  class Fetcher
    # Orphan reclamation for the reliable fetcher (Pro super_fetch §3.2).
    #
    # The Reliable fetcher moves each job from a public queue into a
    # per-process private list (`queue:<public>|<host>|<pid>|<nonce>|<idx>`) and
    # leaves it there until the Processor ACKs. A SIGKILLed or crashed
    # worker therefore strands its in-flight jobs in private lists that
    # nobody will ever ACK. The Reaper is the recovery half: it periodically
    # scans for private lists whose owning process is gone and atomically
    # moves their jobs back to the public queue so a live worker re-runs them.
    #
    # Liveness is decided per owner:
    #   * our own host and nonce — the pid was minted in our PID namespace, so
    #     the OS is authoritative: `Process.kill(0, pid)`. This is instant and
    #     ignores a stale `processes` SET entry whose 60s TTL hasn't lapsed
    #     yet, so a `kill -9`ed sibling is reclaimed the moment the supervisor
    #     reaps it rather than 60s later. (Pid reuse by an unrelated process in
    #     the same tree is the one blind spot — the supervisor respawns with a
    #     fresh pid, so it does not arise in practice.)
    #   * any other incarnation — its pid means nothing in our namespace, so we
    #     trust the heartbeat: the owner is alive iff its identity is a live
    #     `processes` member (one whose `info` hash still exists). Such reclaim
    #     therefore waits out the 60s heartbeat TTL, exactly as the spec says.
    #
    # Re-pushed jobs run through Wurk::Middleware::PoisonPill, which caps a
    # job at RECOVERY_THRESHOLD recoveries within 72h: past the cap the job
    # is killed into the dead set instead of re-queued, so a job that crashes
    # its worker every time can't loop forever.
    #
    # The reaper runs two passes, exactly as super_fetch's sweeper does:
    #
    #   * a *scoped* sweep every interval ("1/min within process group"): SCANs
    #     only the public queues this process serves, gated by a cluster `SET NX
    #     EX` lock so one process sweeps per interval. The cheap common path.
    #   * a *full* sweep at most once an hour ("full SCAN 1/hr"): SCANs the whole
    #     `queue:*|*` keyspace, gated by its own hourly lock, so private lists
    #     whose public queue no live process serves — a renamed/decommissioned
    #     queue, or a dead host's queue no survivor consumes — are recovered too,
    #     not stranded forever.
    #
    # Spec: docs/target/sidekiq-pro.md §3.2.
    class Reaper
      include Component

      # Sweep cadence in seconds; also the cluster-lock TTL so exactly one
      # process sweeps per interval. 60s matches the heartbeat TTL — the
      # floor below which cross-host orphans can't be detected anyway.
      DEFAULT_INTERVAL = 60

      # Full-keyspace sweep cadence + its lock TTL: at most once per hour across
      # the fleet, since a global SCAN is far costlier than the scoped pass.
      FULL_INTERVAL = 3600

      LOCK_KEY = 'super_fetch:reaper'
      FULL_LOCK_KEY = 'super_fetch:reaper:full'
      SCAN_COUNT = 100
      THREAD_NAME = 'wurk-reaper'

      attr_reader :interval

      def initialize(config, interval: DEFAULT_INTERVAL, lock_key: LOCK_KEY,
                     full_interval: FULL_INTERVAL, full_lock_key: FULL_LOCK_KEY)
        @config = config
        @interval = interval
        @lock_key = lock_key
        @full_interval = full_interval
        @full_lock_key = full_lock_key
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

      # Bounded at TimerLoop::JOIN_TIMEOUT like every other periodic component.
      # The full-keyspace sweep is exactly the tick that outlasts a stop: it
      # SCANs the whole `queue:*|*` keyspace and drains what it finds, so on a
      # large or slow Redis it can still be running when shutdown lands. Waiting
      # it out held the entire process's teardown open past the swarm parent's
      # SHUTDOWN_GRACE — which SIGKILLs the child mid-drain, the one outcome
      # this component exists to recover from. A straggler is left running
      # instead — and still referenced, like every other periodic component, so
      # a restart after a timed-out stop can't spawn a second sweep loop
      # alongside it. Its own tick_once rescues and reports.
      def stop
        @mutex.synchronize do
          @done = true
          @sleeper.signal
        end
        @thread = nil if @thread&.join(TimerLoop::JOIN_TIMEOUT)
      end

      def running?
        !@thread.nil? && @thread.alive?
      end

      # One loop tick: the scoped sweep when this process wins the per-interval
      # lock, plus the full-keyspace sweep when it also wins the hourly lock.
      # Returns the total jobs reclaimed across both.
      def reap
        reclaimed = acquire_lock? ? reclaim! : 0
        reclaimed += reclaim_full! if acquire_full_lock?
        reclaimed
      end

      # One unguarded sweep over every served queue. Returns the number of
      # jobs reclaimed (re-queued or killed). Public so boot paths and tests
      # can drive a deterministic pass without the cluster lock.
      def reclaim!
        owners = live_owners
        served_queues.sum { |public_q| reclaim_queue(public_q, owners) }
      end

      # One unguarded full-keyspace sweep: every `queue:*|*` private list, even
      # ones whose public queue this process doesn't serve. Returns the number
      # of jobs reclaimed. Public so boot paths and tests can drive it without
      # the hourly lock.
      def reclaim_full!
        owners = live_owners
        reclaimed = 0
        each_full_private_list do |key, public_q, host, pid, nonce|
          next if owner_alive?(host, pid, nonce, owners)

          reclaimed += drain(key, public_q)
        end
        reclaimed
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
      def reclaim_queue(public_q, owners)
        reclaimed = 0
        each_private_list(public_q) do |key, host, pid, nonce|
          next if owner_alive?(host, pid, nonce, owners)

          reclaimed += drain(key, public_q)
        end
        reclaimed
      end

      # Yields [private_list_key, host, pid, nonce] for each private list of
      # `public_q`. MATCH `<public_q>|*` matches only this queue's private
      # lists (public queue keys carry no `|`).
      def each_private_list(public_q)
        cursor = '0'
        loop do
          cursor, keys = redis(idempotent: true) do |c|
            c.call('SCAN', cursor, 'MATCH', "#{public_q}|*", 'COUNT', SCAN_COUNT)
          end
          keys.each do |key|
            host, pid, nonce = parse_owner(public_q, key)
            yield key, host, pid, nonce if pid
          end
          break if cursor == '0'
        end
      end

      # Yields [private_list_key, public_q, host, pid, nonce] for every list in
      # the keyspace. MATCH `queue:*|*` matches only private lists (public queue
      # keys carry no `|`); parse_full_key drops anything that isn't a
      # well-formed `queue:<public>|<host>|<pid>|<nonce>|<idx>`.
      def each_full_private_list
        cursor = '0'
        loop do
          cursor, keys = redis(idempotent: true) do |c|
            c.call('SCAN', cursor, 'MATCH', "#{Keys::QUEUE_PREFIX}*|*", 'COUNT', SCAN_COUNT)
          end
          keys.each do |key|
            parsed = parse_full_key(key)
            yield key, *parsed if parsed
          end
          break if cursor == '0'
        end
      end

      # `queue:<public>|<host>|<pid>|<nonce>|<idx>` → [public_q, host, pid,
      # nonce], parsed from the right so a `|` inside the queue name is
      # tolerated. nil when the key isn't a well-formed private list.
      #
      # With no known prefix to split on, both owner shapes are tried in
      # preference order and the first one leaving a real public queue behind
      # wins. The narrow reading is what saves a pre-nonce key from an all-digit
      # host (`queue:q|123456789012|<pid>|<idx>` — a bare Docker hostname is 12
      # hex chars): read wide, its host segment eats the whole queue name.
      def parse_full_key(key)
        parts = key.split('|')
        owner_tails(parts).each do |host, pid, nonce, width|
          public_q = parts[0...-width].join('|')
          next unless public_q.start_with?(Keys::QUEUE_PREFIX) && public_q != Keys::QUEUE_PREFIX

          return [public_q, host, pid, nonce]
        end
        nil
      end

      # `<public_q>|<host>|<pid>|<nonce>|<idx>` → [host, pid, nonce] (pid as
      # Integer), or all-nil when the suffix isn't a well-formed owner tail.
      # Splitting the suffix off the known public-queue prefix tolerates a `|`
      # inside the queue name itself, and leaves the tail unambiguous: exactly
      # 4 segments for the current shape, exactly 3 for the pre-nonce one.
      def parse_owner(public_q, key)
        suffix = key.delete_prefix("#{public_q}|")
        return [nil, nil, nil] if suffix == key

        host, pid, nonce = owner_tails(suffix.split('|')).first
        [host, pid, nonce]
      end

      # Owner segments of a private-list key, taken from the right, as
      # [host, pid, nonce, segment_count] readings in preference order (empty
      # when nothing parses). The wide shape is preferred: an all-digit nonce is
      # rare but reachable, and reading such a key narrow would take the pid for
      # the host and the nonce for the pid — draining a live owner's list out
      # from under it.
      def owner_tails(parts)
        return [] unless parts.size >= 3 && integer?(parts[-1])

        [wide_tail(parts), narrow_tail(parts)].compact
      end

      # `<host>|<pid>|<nonce>|<idx>` — the shape every current process writes.
      def wide_tail(parts)
        [parts[-4], parts[-3].to_i, parts[-2], 4] if parts.size >= 4 && integer?(parts[-3])
      end

      # `<host>|<pid>|<idx>` — written before the nonce existed. Such a list can
      # still hold a pre-upgrade process's in-flight jobs across a rolling
      # upgrade, so it stays reclaimable even though nothing writes it anymore.
      def narrow_tail(parts)
        [parts[-3], parts[-2].to_i, nil, 3] if integer?(parts[-2])
      end

      def integer?(str)
        str.is_a?(String) && str.match?(/\A\d+\z/)
      end

      # `Process.kill(0, pid)` answers "does this pid exist *in my PID
      # namespace*", which is the question we're actually asking only when the
      # key was written from that same namespace. A shared hostname does not
      # imply it: a container restarting under a fixed hostname comes back in a
      # fresh namespace where the dead owner's pid is likely taken again (list
      # read as live, jobs stranded forever), and two containers sharing a
      # host's network namespace but not its pid namespace each hold pids the
      # other lacks (live owner read as dead, list drained mid-job, duplicate
      # run). So kill(0) can serve as neither a positive nor a negative signal
      # off our own namespace.
      #
      # The nonce settles it: minted once per process image and inherited across
      # fork, so a key carrying ours provably came from this very process tree.
      # Every other owner goes through the namespace-blind heartbeat — alive iff
      # its identity is a live `processes` member. A pre-nonce key can only be
      # matched on the `<host>:<pid>` prefix of that identity.
      def owner_alive?(host, pid, nonce, owners)
        return local_pid_alive?(pid) if nonce == process_nonce && host == hostname
        return owners.include?("#{host}:#{pid}:#{nonce}") if nonce

        owners.include?("#{host}:#{pid}")
      end

      def local_pid_alive?(pid)
        ::Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # Every live process indexed both ways: the full `<host>:<pid>:<nonce>`
      # identity a nonce-bearing private list is matched on, and the
      # `<host>:<pid>` prefix a pre-nonce one has to settle for. Live means a
      # member of `processes` whose `info` hash still exists — a bare SET
      # membership isn't enough, since the member lingers after its 60s hash
      # TTL until ProcessSet#cleanup prunes it and that window must read as
      # dead or the owner's jobs are never reclaimed.
      def live_owners
        redis(idempotent: true) do |conn|
          members = conn.call('SMEMBERS', Keys::PROCESSES)
          next ::Set.new if members.empty?

          infos = conn.pipelined { |pipe| members.each { |m| pipe.call('HGET', m, 'info') } }
          members.zip(infos).each_with_object(::Set.new) do |(member, info), set|
            set << member << host_pid(member) if info
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
      #
      # Unlike the fetcher's LMOVE, this one does *not* claim apply-safety: a
      # replay after a lost reply moves the next job and never poison-checks the
      # one already on the public tail, so a job that kills its worker every time
      # would get a free recovery past the cap. A raise instead lands in the
      # rescue below, and the next sweep re-drains what's left.
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

      def acquire_full_lock?
        redis { |c| c.call('SET', @full_lock_key, '1', 'NX', 'EX', @full_interval) } == 'OK'
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
