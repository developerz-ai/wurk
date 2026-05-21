# frozen_string_literal: true

require_relative '../test_helper'

class LimiterTest < Wurk::Test::UnitCase
  parallelize_me!

  REDIS_URL = ENV['REDIS_URL'] || 'redis://localhost:6379/0'

  def setup
    super
    @suffix = "ltest#{Process.pid}#{object_id}"
    @pool = Wurk::RedisPool.new(size: 1, url: REDIS_URL, timeout: 2, name: 'ltop')
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
    Wurk::Limiter.reset_config!
    Wurk::Limiter.config.redis = @pool
  end

  def teardown
    # Scope cleanup to this test's @suffix so parallel limiter tests don't
    # wipe each other's state mid-run (failure mode: another test's
    # `within_limit` sees an empty counter because we DEL'd its key).
    @pool.with do |c|
      cursor = '0'
      loop do
        cursor, keys = c.call('SCAN', cursor, 'MATCH', "*#{@suffix}*", 'COUNT', 500)
        c.call('DEL', *keys) unless keys.empty?
        break if cursor == '0'
      end
      cursor = '0'
      loop do
        cursor, names = c.call('SSCAN', Wurk::Limiter::LIST_KEY, cursor, 'MATCH', "*#{@suffix}*", 'COUNT', 500)
        c.call('SREM', Wurk::Limiter::LIST_KEY, *names) unless names.empty?
        break if cursor == '0'
      end
    end
    @pool.disconnect!
    Wurk::Limiter.reset_config!
  ensure
    super
  end

  # ----- constructors dispatch to per-type classes ----------------------

  def test_concurrent_returns_concurrent_instance
    l = Wurk::Limiter.concurrent("cc-#{@suffix}", 1)

    assert_instance_of Wurk::Limiter::Concurrent, l
    assert_equal :concurrent, l.type
    assert_equal "cc-#{@suffix}", l.name
  end

  def test_bucket_returns_bucket_instance
    l = Wurk::Limiter.bucket("bk-#{@suffix}", 1, :minute)

    assert_instance_of Wurk::Limiter::Bucket, l
    assert_equal :bucket, l.type
  end

  def test_window_returns_window_instance
    l = Wurk::Limiter.window("wn-#{@suffix}", 1, :minute)

    assert_instance_of Wurk::Limiter::Window, l
    assert_equal :window, l.type
  end

  def test_leaky_returns_leaky_instance
    l = Wurk::Limiter.leaky("lk-#{@suffix}", 1, 1)

    assert_instance_of Wurk::Limiter::Leaky, l
    assert_equal :leaky, l.type
  end

  def test_points_returns_points_instance
    l = Wurk::Limiter.points("pt-#{@suffix}", 100, 10)

    assert_instance_of Wurk::Limiter::Points, l
    assert_equal :points, l.type
  end

  def test_unlimited_ignores_arguments_and_yields_unconditionally
    l = Wurk::Limiter.unlimited('whatever', 9999, foo: :bar)

    assert_instance_of Wurk::Limiter::Unlimited, l
    assert_equal :unlimited, l.type

    ran = false
    l.within_limit { ran = true }

    assert ran
  end

  # ----- OverLimit shape ------------------------------------------------

  def test_over_limit_exposes_limiter_and_job
    l = Wurk::Limiter.concurrent("ovr-#{@suffix}", 1, wait_timeout: 0)
    job = { 'jid' => 'abc', 'class' => 'X', 'args' => [], 'queue' => 'default' }
    exc = Wurk::Limiter::OverLimit.new(l, job)

    assert_equal l, exc.limiter
    assert_equal job, exc.job
    assert_kind_of StandardError, exc
  end

  # ----- name validation ------------------------------------------------

  def test_constructor_rejects_invalid_name
    assert_raises(ArgumentError) { Wurk::Limiter.concurrent('bad name with spaces', 1) }
  end

  def test_constructor_rejects_ttl_under_24h
    assert_raises(ArgumentError) { Wurk::Limiter.concurrent("ttl-#{@suffix}", 1, ttl: 60) }
  end

  # ----- registration in lmtr-list -------------------------------------

  def test_constructor_registers_in_lmtr_list_and_metadata_hash
    name = "reg-#{@suffix}"
    Wurk::Limiter.concurrent(name, 5)

    @pool.with do |c|
      assert_equal 1, c.call('SISMEMBER', Wurk::Limiter::LIST_KEY, name)
      type = c.call('HGET', "lmtr:#{name}", 'type')

      assert_equal 'concurrent', type
    end
  end

  # ----- delete + reset cleanup ----------------------------------------

  def test_delete_removes_state_keys_and_list_membership
    name = "del-#{@suffix}"
    l = Wurk::Limiter.concurrent(name, 1)
    l.within_limit {} # creates state
    l.delete
    @pool.with do |c|
      assert_equal 0, c.call('SISMEMBER', Wurk::Limiter::LIST_KEY, name)
      assert_equal 0, c.call('EXISTS', "lmtr:#{name}")
      assert_equal 0, c.call('EXISTS', "lmtr-cs:#{name}")
    end
  end

  # ----- configure --------------------------------------------------

  def test_configure_sets_backoff
    Wurk::Limiter.configure { |c| c.backoff = ->(_l, _j, _e) { 42 } }

    assert_equal 42, Wurk::Limiter.config.backoff.call(nil, {}, nil)
  end

  def test_configure_errors_array_can_be_extended
    Wurk::Limiter.config.errors << ArgumentError

    assert_includes Wurk::Limiter.config.errors, ArgumentError
  end

  # ----- fingerprint is SHA256 -----------------------------------------

  def test_fingerprint_is_sha256_hex
    l = Wurk::Limiter.concurrent("fp-#{@suffix}", 1)

    assert_match(/\A[0-9a-f]{64}\z/, l.fingerprint)
  end

  # ----- server middleware reschedule path -----------------------------

  def test_server_middleware_reschedules_on_over_limit
    l = Wurk::Limiter.bucket("mw-#{@suffix}", 1, :minute, wait_timeout: 0, reschedule: 5)
    jid = "mwj#{@suffix}"
    job = { 'class' => 'NoopWorker', 'args' => [1], 'queue' => 'default', 'jid' => jid }
    mw = Wurk::Limiter::ServerMiddleware.new
    mw.config = Wurk.configuration

    begin
      mw.call(nil, job, 'default') { raise Wurk::Limiter::OverLimit.new(l, job) }

      assert_equal 1, job['overrated']
      # Scheduled push lands in the global `schedule` ZSET with score = at.
      scored = Wurk.redis { |c| c.call('ZRANGE', 'schedule', 0, -1) }

      assert(scored.any? { |payload| payload.include?(jid) }, "schedule missing jid: #{scored.inspect}")
    ensure
      Wurk.redis do |c|
        c.call('ZRANGE', 'schedule', 0, -1).each { |p| c.call('ZREM', 'schedule', p) if p.include?(jid) }
      end
    end
  end

  def test_server_middleware_reraises_after_reschedule_cap
    l = Wurk::Limiter.bucket("cap-#{@suffix}", 1, :minute, wait_timeout: 0, reschedule: 2)
    job = { 'class' => 'NoopWorker', 'args' => [], 'queue' => 'default', 'jid' => 'jjj', 'overrated' => 1 }
    mw = Wurk::Limiter::ServerMiddleware.new
    mw.config = Wurk.configuration

    assert_raises(Wurk::Limiter::OverLimit) do
      mw.call(nil, job, 'default') { raise Wurk::Limiter::OverLimit.new(l, job) }
    end
    assert_equal 2, job['overrated']
  end
end
