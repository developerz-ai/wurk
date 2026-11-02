# frozen_string_literal: true

require_relative '../component'
require_relative '../keys'
require_relative '../middleware/poison_pill'
require_relative '../metrics/process_counters'
require_relative '../timer_loop'
require_relative 'private_list_key'
require_relative 'unparseable_keys'
require_relative 'orphan_grace'
require_relative 'oom_drain'
require_relative 'self_reconcile'

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
    #     ignores a stale `processes` SET member — the SET carries no TTL, so
    #     the member lingers after its heartbeat hash expires (60s) until
    #     `ProcessSet#cleanup` prunes it. A `kill -9`ed sibling is reclaimed
    #     the moment the supervisor reaps it, not 60s later. (Pid reuse by an
    #     unrelated process in the same tree is the one blind spot — the
    #     supervisor respawns with a fresh pid, so it does not arise in practice.)
    #   * any other incarnation — its pid means nothing in our namespace, so we
    #     trust the heartbeat: the owner is alive iff its identity's `info`
    #     hash still exists. Such reclaim waits out the 60s heartbeat TTL, the
    #     next sweep and then the grace: 80-150s after the owner died.
    #
    # A missing hash is not proof of death on its own. The verdict is a snapshot
    # taken before a SCAN that can run for a long time on a big keyspace, a beat
    # can be held back by CPU-bound jobs, and a Redis restarted from an older
    # snapshot brings back the `processes` SET with every hash lapsed. So a
    # heartbeat-judged orphan must stay orphaned for `grace` seconds on this
    # process's own clock (OrphanGrace), and its identity must still have no
    # `info` hash. Our own incarnation skips both: kill(0) is not a snapshot.
    #
    # Re-pushed jobs run through Wurk::Middleware::PoisonPill, which caps a
    # job at RECOVERY_THRESHOLD recoveries within 72h: past the cap the job
    # is killed into the dead set instead of re-queued, so a job that crashes
    # its worker every time can't loop forever.
    #
    # One sweep an interval: one SCAN of `queue:*|*` acting on every list, gated
    # by a cluster lock so about one process sweeps per interval. Every list, and
    # not only those this process serves: the lock is shared across the fleet, so
    # a scoped sweep would wait for its turn to land on one of the processes
    # serving the queue. The list's own queue is where its jobs go back to,
    # whichever process moves them.
    #
    # Every tick also runs SelfReconcile over this process's own lists, which is
    # the one case liveness cannot answer: the owner is alive and has lost track
    # of a job.
    #
    # Spec: docs/target/sidekiq-pro.md §3.2.
    class Reaper # rubocop:disable Metrics/ClassLength
      include Component

      # Sweep cadence in seconds. 60s matches the heartbeat TTL — the floor below
      # which cross-host orphans can't be detected anyway.
      DEFAULT_INTERVAL = 60

      # The lock lapses before the winner's next tick, or a sole survivor would
      # still find its own lock there and sweep every second interval.
      LOCK_TTL_RATIO = 0.8

      # Seconds a heartbeat-judged private list stays orphaned before it is
      # drained. A beat is due every 10s, and 25 CPU-bound jobs were measured
      # holding one back 17.4s: at a 15s grace one trial in nine drained all 25
      # live jobs. The price is paid only by a host lost for good.
      DEFAULT_GRACE = 30

      LOCK_KEY = 'super_fetch:reaper'

      # A sweep walks the whole keyspace, where almost nothing matches: COUNT is
      # the work per SCAN call, so a bigger batch is the same server work in a
      # tenth of the round trips — a million keys is 1,000 calls instead of
      # 10,000. Still small enough that one call never holds Redis for more than
      # a fraction of a millisecond.
      SCAN_COUNT = 1000
      THREAD_NAME = 'wurk-reaper'

      attr_reader :interval

      def initialize(config, interval: DEFAULT_INTERVAL, lock_key: LOCK_KEY, grace: DEFAULT_GRACE,
                     reconcile_confirm: SelfReconcile::DEFAULT_CONFIRM)
        @config = config
        @interval = interval
        @grace = OrphanGrace.new(grace)
        @lock_key = lock_key
        @thread = nil
        @done = false
        @mutex = ::Mutex.new
        @sleeper = ::ConditionVariable.new
        @unparseable = UnparseableKeys.new(config)
        @next_sweep_at = 0.0
        @self_reconcile = SelfReconcile.new(config, confirm: reconcile_confirm, stop: -> { done? },
                                                    on_moved: method(:recovered))
      end

      # Spawns the sweep loop. Idempotent. The loop waits one interval before
      # its first sweep so booting processes don't dogpile Redis and so an
      # un-stopped launcher in a unit test never touches the keyspace.
      #
      # A LIVE loop is the one and only sweep loop and is handed back as-is. A
      # dead one is not: a stop whose bounded join timed out leaves its
      # straggler referenced, and once that straggler has wound down the
      # reference is a thread that will never sweep again — handing it back
      # would leave the reaper dead for good, silently, since `start` looked
      # like it had worked. A fresh loop takes its place; while the straggler
      # is still alive it keeps the sweep to itself, so a restart still cannot
      # run two loops at once.
      def start
        @mutex.synchronize do
          return @thread if @thread&.alive?

          @done = false
          @thread = spawn_loop_thread
        end
        @thread
      end

      # Bounded at TimerLoop::JOIN_TIMEOUT like every other periodic component.
      # A sweep is exactly the tick that outlasts a stop: it
      # SCANs the whole `queue:*|*` keyspace and drains what it finds, so on a
      # large or slow Redis it can still be running when shutdown lands. Waiting
      # it out held the entire process's teardown open past the swarm parent's
      # SHUTDOWN_GRACE — which SIGKILLs the child mid-drain, the one outcome
      # this component exists to recover from. A straggler is left running
      # instead — and still referenced, like every other periodic component, so
      # a restart after a timed-out stop can't spawn a second sweep loop
      # alongside it. The sweep honours @done at its queue/list/page
      # boundaries, so a straggler runs at most one more Redis round trip past
      # the stop, not the rest of the keyspace. Its own tick_once rescues and
      # reports.
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

      # One loop tick: a sweep when this process wins the per-interval lock.
      # Returns the jobs reclaimed.
      def reap
        acquire_lock? ? reclaim! : 0
      end

      # One unguarded sweep over every private list. Returns the number of jobs
      # reclaimed (re-queued or killed). Public so boot paths and tests can drive
      # a deterministic pass without the cluster lock.
      #
      # Honours #stop at each boundary: a stop bounding its join leaves the
      # sweep a straggler by design, and the straggler finishes the list it is
      # already draining (its LMOVEs stay applied) but starts nothing new —
      # otherwise it keeps requeueing orphans and holding the sweep locks
      # past the stop, into whatever runs next.
      def reclaim!
        sweep.tap { wake_for_settling }
      end

      # #reclaim! for a booting process. Deliberately under no lock, not even a
      # short one: a replacement's sweep is what recovers the sibling it replaces,
      # and the sibling may have died a moment after another process booted (a
      # 2s lock turned a child killed right after boot from 1s into 61s). One
      # pass per process costs keyspace / SCAN_COUNT calls.
      def boot_reclaim!
        reclaim!
      end

      # Lists whose grace has run out, whichever sweep started it. Runs on every
      # tick with no lock: the sweep lock rotates between processes, and waiting
      # to win it again is what made reclaim slower as a fleet grew. Two processes
      # draining one list is safe, each move takes one job once.
      def drain_settled
        @grace.take_settled.sum do |key, (public_q, host, pid, nonce)|
          next 0 if done?

          owner_gone?(host, pid, nonce) ? drain(key, public_q) : 0
        end
      end

      private

      # A sweep off the loop thread (the boot sweep) may have started a grace the
      # loop's current wait knows nothing about.
      def wake_for_settling
        @mutex.synchronize { @sleeper.signal }
      end

      def sweep
        owners = live_owners
        reclaimed = 0
        each_private_list do |key, owner|
          break if done?
          next unless orphaned?(key, owner, owners)

          reclaimed += drain(key, owner.first)
        end
        reclaimed
      end

      # Yields private_list_key, [public_q, host, pid, nonce] for every list.
      # MATCH `queue:*|*` matches only private lists (public queue
      # keys carry no `|`); PrivateListKey.parse_full drops anything that isn't a
      # well-formed `queue:<public>|<host>|<pid>|<nonce>|<idx>`.
      def each_private_list
        cursor = '0'
        loop do
          break if done?

          cursor, keys = redis(idempotent: true) do |c|
            c.call('SCAN', cursor, 'MATCH', "#{Keys::QUEUE_PREFIX}*|*", 'COUNT', SCAN_COUNT)
          end
          keys.each do |key|
            parsed = PrivateListKey.parse_full(key)
            parsed ? yield(key, parsed) : @unparseable.report(key)
          end
          break if cursor == '0'
        end
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
      # its identity's `info` hash still exists. `processes` membership is not
      # liveness: the SET carries no TTL, so a member outlives the hash that
      # proves it alive, and a nonce-bearing identity is alive on its hash
      # alone even once it has been pruned from the SET. A pre-nonce key can
      # only be matched on the `<host>:<pid>` prefix of that identity.
      def orphaned?(key, owner, owners)
        _public_q, host, pid, nonce = owner
        return !local_pid_alive?(pid) if nonce == process_nonce && host == hostname

        if owners.include?(owner_key(host, pid, nonce))
          @grace.forget(key)
          return false
        end
        return false if @grace.recent?(key, owner)

        owner_gone?(host, pid, nonce)
      end

      def owner_key(host, pid, nonce)
        nonce ? "#{host}:#{pid}:#{nonce}" : "#{host}:#{pid}"
      end

      # The re-check right before a heartbeat-judged drain (see the class doc):
      # the `owners` snapshot may predate the owner's beat, or the whole SCAN.
      # Only reached for lists the snapshot already called orphaned, so its round
      # trips are paid per orphan, never per live list.
      def owner_gone?(host, pid, nonce)
        return !live_owners.include?(owner_key(host, pid, nil)) unless nonce

        redis(idempotent: true) { |c| c.call('HGET', owner_key(host, pid, nonce), 'info') }.nil?
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
          job = redis { |c| reclaim_one(c, private_list, public_q) }
          break unless job

          count += 1
          Metrics::ProcessCounters.increment(:reaper_reclaimed)
          poison_off(public_q, job, queue_name)
        end
        count
      rescue StandardError => e
        handle_exception(e, context: THREAD_NAME)
        count
      end

      # A full Redis must not hold a dead worker's jobs back from the workers
      # still able to drain the queue.
      def reclaim_one(conn, private_list, public_q)
        Wurk::Lua::Loader.eval_cached(conn, :reliable_reclaim, keys: [private_list, public_q], argv: [])
      rescue RedisClient::OutOfMemoryError => e
        OomDrain.reclaim(conn, e, private_list, public_q)
      end

      # SelfReconcile put a payload back: the same accounting as a reclaim, so a
      # job that kills its processor thread every time still hits the poison cap.
      def recovered(public_q, job)
        Metrics::ProcessCounters.increment(:reaper_reclaimed)
        poison_off(public_q, job, public_q.delete_prefix(Keys::QUEUE_PREFIX))
      end

      # The job is back on its queue whatever happens here. Past maxmemory the
      # count can't be taken (nor the job killed, leaving it where it is): raising
      # would end the drain at one job per pass, with the rest of the list waiting
      # on memory they would help free.
      def poison_off(public_q, job, queue_name)
        return unless Middleware::PoisonPill.track!(job, queue: queue_name, config: @config) == :poison

        # track! already ZADDed the payload to the dead set; pull the copy we
        # just moved onto the public tail so it isn't also re-run.
        redis { |c| c.call('LREM', public_q, -1, job) }
      rescue RedisClient::OutOfMemoryError => e
        report(e)
      end

      def acquire_lock?
        ttl = (@interval * LOCK_TTL_RATIO * 1000).ceil
        redis do |c|
          c.call('SET', @lock_key, '1', 'NX', 'PX', ttl)
        rescue RedisClient::OutOfMemoryError => e
          OomDrain.lock(c, e, @lock_key, ttl)
        end == 'OK'
      end

      def spawn_loop_thread
        t = Thread.new { run_loop }
        t.name = THREAD_NAME
        t.report_on_exception = false
        t
      end

      def run_loop
        @next_sweep_at = monotonic + @interval
        until done?
          wait_next
          break if done?

          tick_once
        end
      end

      # Each step guarded on its own: a raise in the sweep (lock contention on a
      # blip, a poison callback) must not cost this process its own reconcile.
      # The wait is cut short for a grace running out (#wait_next), and that
      # wake-up is not a sweep's turn.
      def tick_once
        guarded { reap_when_due }
        guarded { drain_settled }
        guarded { @self_reconcile.sweep }
      end

      def reap_when_due
        now = monotonic
        return if now < @next_sweep_at

        @next_sweep_at = now + @interval
        reap
      end

      def guarded
        yield
      rescue StandardError => e
        report(e)
      end

      # The reporter is host code and may raise too (a closed log stream); that
      # must not end the only thread that recovers orphans.
      def report(error)
        handle_exception(error, context: THREAD_NAME) if @config.respond_to?(:handle_exception)
      rescue StandardError => e
        warn "wurk-reaper: error reporter raised #{e.class}: #{e.message}"
      end

      def wait_next
        wait = [@next_sweep_at - monotonic, @grace.next_due_in].compact.min
        @mutex.synchronize { @sleeper.wait(@mutex, [wait, 0].max) unless @done }
      end

      def monotonic
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end

      def done?
        @mutex.synchronize { @done }
      end
    end
  end
end
