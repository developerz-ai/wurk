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
