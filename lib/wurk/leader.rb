# frozen_string_literal: true

require 'securerandom'
require_relative 'component'
require_relative 'fetcher/oom_drain'
require_relative 'lua'
require_relative 'pool_checkout'
require_relative 'timer_loop'

module Wurk
  # Cluster leader election via Redis `SET NX EX`. Single-leader-per-cluster
  # is best-effort (not Raft): a partitioned ex-leader can briefly co-exist
  # with a new one until the TTL expires. Callers that need strict mutual
  # exclusion must idempotency-guard their writes (see `#token`).
  #
  # Wire-compat: the cluster lock lives at `dear-leader` (STRING, EX≈30s)
  # holding the `<hostname>:<pid>:<process_nonce>` identity. Each fresh
  # gain also pulls a monotonic fencing token via `INCR leader-token`,
  # exposed on `#token`. Wurk goes a small step beyond Sidekiq Enterprise
  # (which deliberately does not expose fencing) so downstream code that
  # *can* benefit from a guard has one available; the token is best-effort
  # too — it is never re-read on subsequent acquires, only on transitions.
  #
  # Cadence per spec: renew every 15s while leader, lock TTL 30s. A follower
  # rechecks when the lease it last read runs out, at most 60s later, and that
  # is what bounds the leaderless time after a SIGKILL: the lease's remaining
  # 15-30s and about a second. Waiting out a flat 60s added up to 60s more. The
  # lock itself is untouched, so a follower still cannot win before the lease
  # has lapsed. The campaign itself starts `initial_wait` seconds
  # after `#start` — the spec fixes the renew/follower/TTL cadence but says
  # nothing about when the first campaign runs, and holding it back keeps a
  # booting process's opening Redis round trips on the job path. Opt out a
  # process from campaigning entirely with `WURK_LEADER=false` (or its Sidekiq
  # alias `SIDEKIQ_LEADER=false`), useful for hot-standby pools.
  #
  # Spec: docs/target/sidekiq-ent.md §6.
  class Leader
    DEFAULT_KEY = 'dear-leader'
    TOKEN_KEY = 'leader-token'
    DEFAULT_TTL = 30
    DEFAULT_RENEW_INTERVAL = 15
    DEFAULT_FOLLOWER_INTERVAL = 60
    # Delay before the campaign's first `SET NX EX`, so a booting process
    # spends its opening Redis round trips on fetching jobs rather than on a
    # leadership CAS. Every leader-gated consumer (cron, both rollups,
    # history) waits out a 30-60s interval before its own first tick, so
    # nothing observes the gap. Tune with `config[:leader_initial_wait]`;
    # 0 campaigns immediately.
    DEFAULT_INITIAL_WAIT = 1
    # Followers spread out over this many seconds past the lease's end, so a
    # large fleet doesn't campaign in one instant.
    LEASE_EXPIRY_JITTER = 1.0
    # Keeps a lease read as about to lapse from turning into a busy loop.
    MIN_FOLLOWER_WAIT = 0.05
    # The renewal has to survive a full Redis: a lapsed lease stops every
    # leader-gated consumer, and nothing would renew it until memory came back.
    # Shebang scripts, so by EVAL for the reason Fetcher::OomDrain gives. A server
    # refusing one raises the original OOM, the failure without this.
    OOM_CAMPAIGN = "#{Fetcher::OomDrain::HEADER}#{Lua::SCRIPTS.fetch(:leader_campaign)}".freeze
    OOM_TOKEN = "#{Fetcher::OomDrain::HEADER}return redis.call('INCR', KEYS[1])\n".freeze
    OPT_OUT_ENV = 'WURK_LEADER'            # native opt-out env
    SIDEKIQ_OPT_OUT_ENV = 'SIDEKIQ_LEADER' # Sidekiq Ent drop-in alias (§6.2/§7.2)
    THREAD_NAME = 'wurk-leader'

    # True when this process has opted out of campaigning via `WURK_LEADER=false`
    # or its Sidekiq alias `SIDEKIQ_LEADER=false` (hot-standby pools that must
    # never lead). Either env name works.
    def self.opted_out?
      [OPT_OUT_ENV, SIDEKIQ_OPT_OUT_ENV].any? { |k| ENV[k].to_s.downcase == 'false' }
    end

    attr_reader :key, :ttl, :owner, :token, :config

    def initialize(config: nil, key: DEFAULT_KEY, ttl: DEFAULT_TTL,
                   renew_interval: DEFAULT_RENEW_INTERVAL,
                   follower_interval: DEFAULT_FOLLOWER_INTERVAL,
                   initial_wait: DEFAULT_INITIAL_WAIT,
                   pool: nil, owner: nil)
      @config = config
      @key = key
      @ttl = ttl
      @renew_interval = renew_interval
      @follower_interval = follower_interval
      @initial_wait = initial_wait.to_f
      @pool = pool
      @owner = owner || cluster_identity
      @held = false
      @token = nil
      @lease_remaining = nil
      @campaign_failed = false
      @thread = nil
      @done = false
      @mutex = ::Mutex.new
      @sleeper = ::ConditionVariable.new
    end

    # `WURK_LEADER=false` (or `SIDEKIQ_LEADER=false`) makes `acquire` a no-op and
    # `leader?` permanently false; the renewal thread also refuses to start.
    # Useful for hot-standby pools that must never campaign.
    def disabled?
      self.class.opted_out?
    end

    # SET NX EX. If the key already holds *our* owner string (rare — same
    # process re-entering after a hiccup), refresh its TTL so leadership
    # doesn't lapse — both in one script (lua/leader_campaign.lua), so the
    # refresh can't land on a lock a follower took in between. On any
    # follower → leader transition, INCR the global
    # `leader-token` so the new token is strictly greater than every prior
    # leader's, then dispatch the `:leader` lifecycle event.
    def acquire # rubocop:disable Naming/PredicateMethod
      return false if disabled?

      transition = run_set_or_refresh
      return false unless transition

      if transition == :gained
        @token = redis_call { |c| next_token(c) }
        dispatch_leader_event
      end
      true
    end

    # CAS DEL — only drop the key if we still own it, otherwise a stale
    # release would yank leadership from whichever follower took over.
    # GET-then-DEL is not that CAS: our key can lapse between the two
    # commands and a follower can win the election in the gap, whereupon
    # the bare DEL deletes *its* lock and leaves the cluster leaderless
    # (or, once the ex-leader re-campaigns, doubly led) for up to one
    # renew interval — double cron fires, double rollups. The compare and
    # the delete happen in one server-side step instead, via the script
    # `Unique.release_if_owner` already shares.
    #
    # `idempotent:` — a replay after a lost reply finds the key either
    # already gone or no longer ours, so it can only be a no-op.
    def release
      redis_call(idempotent: true) do |c|
        Wurk::Lua::Loader.eval_cached(c, :release_if_owner, keys: [@key], argv: [@owner])
      end
      @held = false
      @token = nil
      nil
    end

    def leader?
      @held
    end

    # Spawns the periodic re-election thread. Idempotent. While leader,
    # the loop re-acquires (refreshing TTL) every `renew_interval`; while
    # follower, it polls every `follower_interval`. Caller must invoke
    # `stop` for orderly shutdown — the thread also releases its lock on
    # exit.
    #
    # The spawn happens *inside* the lock: with it outside, two callers
    # racing into `start` both clear the nil check and both spawn, and the
    # loser's loop is never recorded — an unjoinable second campaigner that
    # outlives `stop` and keeps renewing the cluster lock.
    def start
      return nil if disabled?

      @mutex.synchronize do
        return @thread if @thread

        @done = false
        @thread = spawn_loop_thread
      end
      @thread
    end

    # Bounded at TimerLoop::JOIN_TIMEOUT like every other periodic component: a
    # tick parked on a wedged Redis (the campaign waits out the socket
    # timeouts) must not hold the whole process's teardown open — the swarm
    # parent SIGKILLs a child that overruns its shutdown grace.
    #
    # Releases only once the loop is confirmed gone. A straggler still inside
    # its campaign could otherwise re-take the lock right after this release,
    # leaving a stopping process as leader for a full TTL; the straggler's own
    # trailing release (#run_loop) covers that case instead, and the TTL
    # covers a straggler that never comes back. A straggler also stays
    # referenced, so a restart after a timed-out stop can't campaign twice in
    # parallel.
    # Stops the campaign without releasing the lock or waiting: for a shutdown
    # that still has loops in flight, which must finish under the lock.
    def signal_stop
      @mutex.synchronize do
        @done = true
        @sleeper.signal
      end
    end

    def stop
      signal_stop
      thread = @mutex.synchronize { @thread }
      return unless thread.nil? || thread.join(TimerLoop::JOIN_TIMEOUT)

      @mutex.synchronize { @thread = nil }
      release
    end

    def running?
      !@thread.nil? && @thread.alive?
    end

    private

    # Returns `:gained` on first acquisition, `:held` on renewal, or `nil`
    # if another process currently holds the key. Sets `@held` accordingly
    # so `leader?` reflects the latest state regardless of branch.
    def run_set_or_refresh
      won = redis_call { |c| campaign(c) }
      if won.to_i == 1
        outcome = @held ? :held : :gained
        @held = true
        return outcome
      end

      step_down
      read_lease_remaining
      nil
    end

    def campaign(conn)
      Wurk::Lua::Loader.eval_cached(conn, :leader_campaign, keys: [@key], argv: [@owner, @ttl])
    rescue RedisClient::OutOfMemoryError => e
      past_maxmemory(e) { conn.call('EVAL', OOM_CAMPAIGN, 1, @key, @owner, @ttl) }
    end

    def next_token(conn)
      conn.call('INCR', TOKEN_KEY)
    rescue RedisClient::OutOfMemoryError => e
      past_maxmemory(e) { conn.call('EVAL', OOM_TOKEN, 1, TOKEN_KEY) }
    end

    def past_maxmemory(error)
      yield
    rescue RedisClient::ConnectionError
      raise
    rescue RedisClient::CommandError
      raise error
    end

    # Seconds until the holder's lease runs out; nil for a lock with no TTL, which
    # only expiry cannot free. A lock gone again already is a zero wait.
    def read_lease_remaining
      pttl = redis_call(idempotent: true) { |c| c.call('PTTL', @key) }
      @lease_remaining = pttl == -1 ? nil : [pttl, 0].max / 1000.0
    end

    def step_down
      @held = false
      @token = nil
    end

    def dispatch_leader_event
      return if @config.nil?
      return unless @config.respond_to?(:[])

      bucket = @config[:lifecycle_events]&.[](:leader)
      return if bucket.nil? || bucket.empty?

      bucket.each { |hook| invoke_hook(hook) }
    end

    def invoke_hook(hook)
      hook.call
    rescue StandardError => e
      @config.handle_exception(e, event: :leader) if @config.respond_to?(:handle_exception)
    end

    def redis_call(idempotent: false, &)
      if @pool
        PoolCheckout.with(@pool, idempotent, &)
      elsif @config
        @config.redis(idempotent:, &)
      else
        Wurk.redis(idempotent:, &)
      end
    end

    # Matches `Wurk::Component#identity` so `ProcessSet::Process#leader?`
    # (which compares `dear-leader == process.identity`) sees a match.
    def cluster_identity
      Component.identity
    end

    def spawn_loop_thread
      t = Thread.new { run_loop }
      t.name = THREAD_NAME
      t.report_on_exception = false
      t
    end

    def run_loop
      wait_initial
      until done?
        tick_once
        wait_next
      end
      release_on_exit
    end

    # The thread is exiting either way; a Redis error here is reported, not
    # left to kill the thread silently (report_on_exception is off). The lock
    # then lapses on its TTL.
    def release_on_exit
      release
    rescue StandardError => e
      report(e)
    end

    # Same condvar as #wait_next, so a `stop` landing inside the pre-campaign
    # delay wakes the loop immediately instead of holding shutdown open for a
    # whole initial_wait.
    def wait_initial
      wait_for(@initial_wait) if @initial_wait.positive?
    end

    # An unconfirmed campaign means we can't claim the lock: keeping @held
    # would leave every leader-gated consumer acting as leader through an
    # outage long enough for a follower to take over, and would keep this loop
    # on the short renew cadence. Stepping down makes the next success a fresh
    # gain — a new fencing token and a re-fired `:leader` event. It says nothing
    # about the lease, so the retry is on the renew cadence, not the follower's:
    # a leader that failed one renewal still has time to keep its lease.
    def tick_once
      @campaign_failed = false
      acquire
    rescue StandardError => e
      @campaign_failed = true
      step_down
      report(e)
    end

    def report(error)
      @config.handle_exception(error, context: THREAD_NAME) if @config.respond_to?(:handle_exception)
    end

    def wait_next
      wait_for(@held || @campaign_failed ? @renew_interval : follower_wait)
    end

    def follower_wait
      return @follower_interval unless @lease_remaining

      [@lease_remaining + (rand * LEASE_EXPIRY_JITTER), @follower_interval].min.clamp(MIN_FOLLOWER_WAIT, nil)
    end

    def wait_for(interval)
      @mutex.synchronize { @sleeper.wait(@mutex, interval) unless @done }
    end

    def done?
      @mutex.synchronize { @done }
    end
  end
end
