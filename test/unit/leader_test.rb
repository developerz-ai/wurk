# frozen_string_literal: true

require_relative '../test_helper'

class LeaderTest < Wurk::Test::UnitCase
  parallelize_me!

  # Tests touch process-global ENV['WURK_LEADER'] and (in one case) the
  # shared `dear-leader` STRING. Serialize those — parallel runners would
  # otherwise see each other's ENV writes mid-flight.
  ENV_MUTEX = Mutex.new
  CLUSTER_KEY_MUTEX = Mutex.new

  def setup
    super
    @suffix = "leader-#{Process.pid}-#{object_id}"
    @key = "leader-test:#{@suffix}"
    @leaders = []
  end

  def teardown
    @leaders.each do |ldr|
      ldr.stop if ldr.running?
      ldr.release
    end
    Wurk.redis { |c| c.call('DEL', @key) }
  ensure
    super
  end

  # ---- API surface ------------------------------------------------------

  def test_default_key_is_dear_leader
    assert_equal 'dear-leader', Wurk::Leader::DEFAULT_KEY
  end

  def test_token_key_is_leader_token
    assert_equal 'leader-token', Wurk::Leader::TOKEN_KEY
  end

  def test_default_ttl_thirty_seconds
    assert_equal 30, Wurk::Leader::DEFAULT_TTL
  end

  def test_default_renew_is_half_ttl
    assert_equal Wurk::Leader::DEFAULT_TTL / 2, Wurk::Leader::DEFAULT_RENEW_INTERVAL
  end

  # ---- Owner identity ---------------------------------------------------

  def test_owner_matches_component_identity_format
    ldr = build_leader

    assert_match(/\A.+:#{Process.pid}:[0-9a-f]{12}\z/, ldr.owner)
  end

  def test_owner_explicit_override
    ldr = build_leader(owner: 'host-x:99:abcdef')

    assert_equal 'host-x:99:abcdef', ldr.owner
  end

  # ---- acquire / release ------------------------------------------------

  def test_acquire_returns_true_when_lock_available
    ldr = build_leader

    assert ldr.acquire
    assert_predicate ldr, :leader?
  end

  def test_acquire_writes_owner_to_key
    ldr = build_leader
    ldr.acquire

    assert_equal(ldr.owner, Wurk.redis { |c| c.call('GET', @key) })
  end

  def test_acquire_sets_ttl
    ldr = build_leader(ttl: 5)
    ldr.acquire
    ttl = Wurk.redis { |c| c.call('TTL', @key) }

    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, 5
  end

  def test_second_acquire_returns_false_for_competitor
    a = build_leader(owner: 'a-owner')
    b = build_leader(owner: 'b-owner')

    assert a.acquire
    refute b.acquire
    refute_predicate b, :leader?
  end

  # Failover primitive: once the holder steps down, a different owner wins.
  def test_competitor_acquires_after_holder_releases
    a = build_leader(owner: 'a-owner')
    b = build_leader(owner: 'b-owner')
    a.acquire

    refute b.acquire, 'competitor blocked while the lock is held'
    a.release

    assert b.acquire, 'competitor takes over once the holder releases'
    assert_predicate b, :leader?
  end

  def test_re_acquire_refreshes_ttl
    ldr = build_leader(ttl: 30)
    ldr.acquire
    ttl_before = Wurk.redis { |c| c.call('TTL', @key) }
    Wurk.redis { |c| c.call('EXPIRE', @key, 5) }
    ldr.acquire

    ttl_after = Wurk.redis { |c| c.call('TTL', @key) }

    assert_operator ttl_after, :>, ttl_before - 5
  end

  def test_release_drops_key_when_owner
    ldr = build_leader
    ldr.acquire
    ldr.release

    assert_nil(Wurk.redis { |c| c.call('GET', @key) })
    refute_predicate ldr, :leader?
  end

  def test_release_is_cas_only
    a = build_leader
    a.acquire
    Wurk.redis { |c| c.call('SET', @key, 'someone-else') }
    a.release

    assert_equal('someone-else', Wurk.redis { |c| c.call('GET', @key) })
  end

  # ---- Fencing token ----------------------------------------------------

  def test_token_nil_before_acquire
    ldr = build_leader

    assert_nil ldr.token
  end

  def test_token_assigned_on_acquire
    ldr = build_leader
    ldr.acquire

    assert_kind_of Integer, ldr.token
    assert_operator ldr.token, :>, 0
  end

  def test_token_monotonic_across_acquisitions
    a = build_leader
    b = build_leader

    a.acquire
    first = a.token
    a.release
    b.acquire

    assert_operator b.token, :>, first
  end

  def test_token_unchanged_on_renewal
    ldr = build_leader
    ldr.acquire
    initial = ldr.token
    ldr.acquire

    assert_equal initial, ldr.token
  end

  def test_token_cleared_when_losing_election
    a = build_leader(owner: 'a-owner')
    a.acquire

    refute_nil a.token

    b = build_leader(owner: 'b-owner')

    refute b.acquire

    assert_nil b.token
  end

  def test_token_cleared_after_release
    ldr = build_leader
    ldr.acquire
    ldr.release

    assert_nil ldr.token
  end

  # ---- Opt-out ----------------------------------------------------------

  def test_opt_out_disables_acquire
    with_env('WURK_LEADER', 'false') do
      ldr = build_leader

      refute ldr.acquire
      assert_predicate ldr, :disabled?
    end
  end

  def test_opt_out_skips_redis_write
    with_env('WURK_LEADER', 'false') do
      build_leader.acquire

      assert_nil(Wurk.redis { |c| c.call('GET', @key) })
    end
  end

  def test_opt_out_keeps_leader_predicate_false
    with_env('WURK_LEADER', 'false') do
      ldr = build_leader
      ldr.acquire

      refute_predicate ldr, :leader?
    end
  end

  def test_opt_out_blocks_start
    with_env('WURK_LEADER', 'false') do
      ldr = build_leader
      result = ldr.start

      assert_nil result
      refute_predicate ldr, :running?
    end
  end

  def test_opt_out_is_case_insensitive
    with_env('WURK_LEADER', 'FALSE') do
      assert_predicate build_leader, :disabled?
    end
  end

  # ---- :leader lifecycle event -----------------------------------------

  def test_leader_event_fires_once_on_gain
    config = build_config
    fired = 0
    config.on(:leader) { fired += 1 }
    ldr = build_leader(config: config)

    ldr.acquire
    ldr.acquire

    assert_equal 1, fired
  end

  def test_leader_event_refires_after_losing_and_regaining
    config = build_config
    fired = 0
    config.on(:leader) { fired += 1 }
    ldr = build_leader(config: config)

    ldr.acquire
    ldr.release
    ldr.acquire

    assert_equal 2, fired
  end

  def test_leader_event_skipped_when_no_config
    ldr = build_leader(config: nil)

    ldr.acquire

    pass # no exception is the assertion — bucketless dispatch is a no-op
  end

  def test_leader_event_handler_error_reported
    config = build_config
    seen = []
    config.error_handlers << ->(ex, ctx, _cfg) { seen << [ex.message, ctx] }
    config.on(:leader) { raise 'leader-hook-boom' }
    ldr = build_leader(config: config)
    ldr.acquire

    assert_equal [['leader-hook-boom', { event: :leader }]], seen
  end

  # ---- Component#leader? -----------------------------------------------

  def test_component_leader_predicate_true_when_dear_leader_matches_identity
    CLUSTER_KEY_MUTEX.synchronize do
      config = build_config
      host = component_host(config)
      Wurk.redis { |c| c.call('SET', 'dear-leader', host.identity, 'EX', 5) }

      assert_predicate host, :leader?
    ensure
      Wurk.redis { |c| c.call('DEL', 'dear-leader') }
    end
  end

  def test_component_leader_predicate_false_when_unset
    CLUSTER_KEY_MUTEX.synchronize do
      Wurk.redis { |c| c.call('DEL', 'dear-leader') }
      host = component_host(build_config)

      refute_predicate host, :leader?
    end
  end

  def test_component_leader_predicate_false_when_other_owner
    CLUSTER_KEY_MUTEX.synchronize do
      Wurk.redis { |c| c.call('SET', 'dear-leader', 'someone-else', 'EX', 5) }
      host = component_host(build_config)

      refute_predicate host, :leader?
    ensure
      Wurk.redis { |c| c.call('DEL', 'dear-leader') }
    end
  end

  def test_component_leader_predicate_honors_opt_out
    CLUSTER_KEY_MUTEX.synchronize do
      host = component_host(build_config)
      Wurk.redis { |c| c.call('SET', 'dear-leader', host.identity, 'EX', 5) }

      with_env('WURK_LEADER', 'false') do
        refute_predicate host, :leader?
      end
    ensure
      Wurk.redis { |c| c.call('DEL', 'dear-leader') }
    end
  end

  # ---- Periodic re-election thread -------------------------------------

  def test_start_returns_thread_and_running
    ldr = build_leader(renew_interval: 0.05, follower_interval: 0.05)
    t = ldr.start

    assert_kind_of Thread, t
    assert_predicate ldr, :running?
  end

  def test_start_is_idempotent
    ldr = build_leader(renew_interval: 0.05, follower_interval: 0.05)
    t1 = ldr.start
    t2 = ldr.start

    assert_same t1, t2
  end

  def test_periodic_loop_acquires_when_available
    ldr = build_leader(renew_interval: 0.05, follower_interval: 0.05)
    ldr.start
    deadline = Time.now + 2
    sleep 0.05 until ldr.leader? || Time.now > deadline

    assert_predicate ldr, :leader?
  end

  def test_stop_releases_and_clears_thread
    ldr = build_leader(renew_interval: 0.05, follower_interval: 0.05)
    ldr.start
    deadline = Time.now + 2
    sleep 0.05 until ldr.leader? || Time.now > deadline
    ldr.stop

    refute_predicate ldr, :running?
    refute_predicate ldr, :leader?
    assert_nil(Wurk.redis { |c| c.call('GET', @key) })
  end

  def test_thread_name_set_for_observability
    ldr = build_leader(renew_interval: 0.05, follower_interval: 0.05)
    t = ldr.start

    assert_equal Wurk::Leader::THREAD_NAME, t.name
  end

  # ---- run_set_or_refresh branch coverage ------------------------------

  # SET NX succeeds while we still believe we hold the lock (key lapsed/was
  # dropped out from under us): outcome is :held, not :gained. Covers the
  # `@held ? :held` then-side at leader.rb:135.
  def test_reacquire_after_key_dropped_keeps_held_outcome
    config = build_config
    fired = 0
    config.on(:leader) { fired += 1 }
    ldr = build_leader(config: config)

    ldr.acquire # first gain → fired == 1
    Wurk.redis { |c| c.call('DEL', @key) }

    assert ldr.acquire, 're-acquires the freed key'

    # :held, not :gained — the re-acquire fires no second :leader event.
    assert_equal 1, fired
    assert_predicate ldr, :leader?
  end

  # Key already holds our owner but @held is still false (e.g. a prior
  # process wrote it, or we never recorded the gain): the EXPIRE-refresh
  # path must report :gained. Covers the `: :gained` else-side at
  # leader.rb:142 and dispatches the event.
  def test_acquire_adopts_preexisting_owned_key_as_gain
    config = build_config
    fired = 0
    config.on(:leader) { fired += 1 }
    ldr = build_leader(config: config)

    Wurk.redis { |c| c.call('SET', @key, ldr.owner, 'EX', 30) }

    assert ldr.acquire, 'SET NX fails, GET==owner, EXPIRE refresh'
    assert_predicate ldr, :leader?
    # The :leader event fires only on a :gained transition, so a single
    # dispatch proves the EXPIRE path returned :gained (and INCRed a token).
    assert_equal 1, fired, 'adoption counts as a gain'
  end

  # ---- redis_call pool branch ------------------------------------------

  # When constructed with an explicit pool, redis_call routes through it.
  # Covers the `@pool.with(&)` then-side at leader.rb:171.
  def test_acquire_uses_explicit_pool
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, timeout: 2, name: 'leader-pool')
    ldr = Wurk::Leader.new(key: @key, pool: pool)

    assert ldr.acquire
    assert_equal(ldr.owner, pool.with { |c| c.call('GET', @key) })
  ensure
    ldr&.release
    pool&.disconnect!
  end

  # ---- dispatch_leader_event branches ----------------------------------

  # Config object that does not respond to []: dispatch bails at the
  # respond_to?(:[]) guard. Covers leader.rb:155 then-side. redis_call is
  # routed through a pool so the bare config double is never asked for #redis.
  def test_dispatch_skipped_when_config_has_no_index
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, timeout: 2, name: 'leader-noidx')
    bare = Object.new # responds to neither [] nor handle_exception
    ldr = Wurk::Leader.new(key: @key, pool: pool, config: bare)

    assert ldr.acquire # no NoMethodError despite a gain transition
    assert_predicate ldr, :leader?
  ensure
    ldr&.release
    pool&.disconnect!
  end

  # Config responds to [] but has no lifecycle_events entry: bucket is nil,
  # dispatch returns at the nil/empty guard. Covers the `&.` else-side at
  # leader.rb:157.
  def test_dispatch_skipped_when_no_lifecycle_bucket
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, timeout: 2, name: 'leader-nobucket')
    cfg = empty_index_config
    ldr = Wurk::Leader.new(key: @key, pool: pool, config: cfg)

    assert ldr.acquire
    assert_predicate ldr, :leader?
  ensure
    ldr&.release
    pool&.disconnect!
  end

  # A :leader hook raises and the config cannot report it (no
  # handle_exception): invoke_hook swallows the error. Covers the rescue
  # else-side at leader.rb:166.
  def test_hook_error_swallowed_when_config_cannot_report
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, timeout: 2, name: 'leader-noreport')
    cfg = hook_config([-> { raise 'boom-no-reporter' }])
    ldr = Wurk::Leader.new(key: @key, pool: pool, config: cfg)

    assert ldr.acquire # rescue eats it, acquire still succeeds
    assert_predicate ldr, :leader?
  ensure
    ldr&.release
    pool&.disconnect!
  end

  # ---- stop without start ----------------------------------------------

  # stop before start: @thread is nil so the `&.join` short-circuits.
  # Covers the safe-navigation else-side at leader.rb:117.
  def test_stop_without_start_is_noop
    ldr = build_leader
    ldr.acquire

    ldr.stop # no thread to join

    refute_predicate ldr, :running?
    assert_nil(Wurk.redis { |c| c.call('GET', @key) }) # release still ran
  end

  # ---- tick_once rescue + follower wait --------------------------------

  # acquire raises inside the loop and config CAN report it: tick_once
  # forwards to handle_exception. Covers leader.rb:209 then-side. The loop
  # also ticks as a follower (never leader), exercising the follower_interval
  # else-side at leader.rb:214.
  def test_loop_reports_tick_errors_and_keeps_running
    seen = Queue.new
    cfg = reporting_config { |ex, ctx| seen << [ex.message, ctx] }
    pool = raising_pool
    ldr = Wurk::Leader.new(key: @key, pool: pool, config: cfg,
                           renew_interval: 0.02, follower_interval: 0.02)
    ldr.start

    msg, ctx = wait_for_dequeue(seen)

    assert_equal 'pool-down', msg
    assert_equal Wurk::Leader::THREAD_NAME, ctx
    refute_predicate ldr, :leader? # never gained → follower wait path
  ensure
    stop_quietly(ldr) # release() also hits the raising pool — ignore it
  end

  # Drive the stop-during-tick race deterministically: the first tick blocks
  # in the pool until we have already requested stop (@done = true). When the
  # tick returns, wait_next sees @done already set and skips the wait — the
  # `unless @done` else-side at leader.rb:214.
  def test_wait_skipped_when_stop_requested_during_tick
    in_tick = Queue.new
    release_tick = Queue.new
    pool = gated_pool(in_tick, release_tick)
    ldr = Wurk::Leader.new(key: @key, pool: pool, config: nil,
                           renew_interval: 5, follower_interval: 5)
    ldr.start

    in_tick.pop # loop is parked inside the first tick's pool call
    stopper = Thread.new { ldr.stop } # sets @done, signals, then joins
    Thread.pass until ldr.instance_variable_get(:@done) # @done is now true
    release_tick << :go # tick returns → wait_next entered with @done true

    stopper.join(5)

    refute_predicate ldr, :running?
  ensure
    release_tick << :go # unblock any later pool call (release on exit)
    stop_quietly(ldr)
  end

  # acquire raises inside the loop and there is no config to report to:
  # tick_once swallows it. Covers leader.rb:209 else-side. The loop must
  # keep running rather than crash.
  def test_loop_swallows_tick_errors_without_config
    calls = Queue.new
    pool = raising_pool(calls)
    ldr = Wurk::Leader.new(key: @key, pool: pool, config: nil,
                           renew_interval: 0.02, follower_interval: 0.02)
    ldr.start

    # Wait until the loop has actually ticked (and thus rescued a raise with
    # no config to report to). The thread stays alive despite each raise.
    wait_for_dequeue(calls)

    assert_predicate ldr, :running?
    refute_predicate ldr, :leader?
  ensure
    stop_quietly(ldr) # release() also hits the raising pool — ignore it
  end

  private

  def build_leader(**)
    ldr = Wurk::Leader.new(key: @key, **)
    @leaders << ldr
    ldr
  end

  def build_config
    cfg = Wurk::Configuration.new
    cfg.logger = ::Logger.new(IO::NULL)
    cfg
  end

  def component_host(config)
    Class.new do
      include Wurk::Component

      attr_reader :config

      def initialize(cfg) = @config = cfg
    end.new(config)
  end

  # Config double that responds to [] but has no lifecycle_events entry.
  def empty_index_config
    Class.new do
      def [](_key) = nil
    end.new
  end

  # Config double exposing a :leader hook bucket via [] but with no
  # handle_exception, so a raising hook cannot be reported.
  def hook_config(hooks)
    Class.new do
      def initialize(hooks) = @events = { lifecycle_events: { leader: hooks } }

      def [](key) = @events[key]
    end.new(hooks)
  end

  # Config double that records handle_exception calls. No lifecycle bucket,
  # so a successful gain dispatches nothing; only loop errors flow through.
  def reporting_config(&recorder)
    Class.new do
      def initialize(recorder) = @recorder = recorder

      def [](_key) = nil

      def handle_exception(ex, ctx = {})
        @recorder.call(ex, ctx[:context])
      end
    end.new(recorder)
  end

  # A real pool whose connections raise on every call, so acquire fails
  # inside the loop. Not a Redis mock — the pool/connection are real
  # objects; only the wrapped block call is forced to raise.
  def raising_pool(calls = nil)
    conn = Class.new do
      def initialize(calls) = @calls = calls

      def call(*)
        @calls << :tick if @calls
        raise(StandardError, 'pool-down')
      end
    end.new(calls)
    Class.new do
      def initialize(conn) = @conn = conn

      def with = yield(@conn)
    end.new(conn)
  end

  # stop() joins the loop thread and then release()s, which routes through
  # the raising pool. The raise is the point of the test; swallow it here so
  # teardown stays clean.
  def stop_quietly(ldr)
    ldr&.stop
  rescue StandardError
    nil
  end

  # Pool that blocks the *first* `with` call until released, signalling when
  # entered. Later calls pass straight through. Yields a connection that no-ops
  # every command so acquire/release run without touching real Redis.
  def gated_pool(in_tick, release_tick)
    conn = Class.new do
      # SET NX returns nil (not "OK") and GET returns nil so acquire is a
      # clean follower no-gain — we only care about the wait_next branch.
      def call(*) = nil
    end.new
    Class.new do
      def initialize(conn, entered, gate)
        @conn = conn
        @entered = entered
        @gate = gate
        @first = true
      end

      def with
        if @first
          @first = false
          @entered << :in
          @gate.pop
        end
        yield(@conn)
      end
    end.new(conn, in_tick, release_tick)
  end

  def wait_for_dequeue(queue, timeout: 3)
    deadline = Time.now + timeout
    sleep 0.01 while queue.empty? && Time.now < deadline
    raise 'timed out waiting for handle_exception' if queue.empty?

    queue.pop
  end

  def with_env(key, value)
    ENV_MUTEX.synchronize do
      prior = ENV.fetch(key, nil)
      ENV[key] = value
      yield
    ensure
      prior.nil? ? ENV.delete(key) : ENV[key] = prior
    end
  end
end
