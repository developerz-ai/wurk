# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

class MetricsHistoryTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @at = ::Time.utc(2026, 5, 21, 14, 37, 12)
    # SecureRandom, not object_id: object_ids are recycled after GC, so a
    # later instance could inherit an earlier one's bucket field and see a
    # doubled count. A unique-per-instance class guarantees no field collision.
    @klass = "FooJob-#{SecureRandom.hex(8)}"
  end

  def teardown
    Wurk.redis do |c|
      cursor = '0'
      loop do
        cursor, keys = c.call('SCAN', cursor, 'MATCH', "*#{@klass}*", 'COUNT', 500)
        c.call('DEL', *keys) unless keys.empty?
        break if cursor == '0'
      end
      # Per-class fields live in shared, non-class-named minute/rollup buckets
      # that SCAN can't reach. HDEL our fields from every bucket this test
      # could have written: the fixed @at bucket (record tests) AND the
      # current-time bucket (middleware tests record at Time.now).
      bucket_keys = [@at, ::Time.now.utc].flat_map do |t|
        [Wurk::Metrics::History.minute_key(t), Wurk::Metrics::History.rollup_key(t)]
      end
      bucket_keys.uniq.each do |key|
        c.call('HDEL', key, "#{@klass}|p", "#{@klass}|f", "#{@klass}|ms")
      end
    end
  ensure
    super
  end

  # ---- bucket key formatting -----------------------------------------------

  def test_minute_key_format
    assert_equal 'j|260521|14:37', Wurk::Metrics::History.minute_key(@at)
  end

  def test_rollup_key_zeroes_last_digit_of_minute
    assert_equal 'j|260521|14:30', Wurk::Metrics::History.rollup_key(@at)
    assert_equal 'j|260521|14:30', Wurk::Metrics::History.rollup_key(::Time.utc(2026, 5, 21, 14, 39))
    assert_equal 'j|260521|14:40', Wurk::Metrics::History.rollup_key(::Time.utc(2026, 5, 21, 14, 40))
  end

  def test_hour_key_format
    assert_equal 'FooJob-260521-14', Wurk::Metrics::History.hour_key('FooJob', @at)
  end

  def test_minute_key_uses_utc
    local_time = ::Time.utc(2026, 5, 21, 23, 30) + 60

    assert_equal 'j|260521|23:31', Wurk::Metrics::History.minute_key(local_time)
  end

  # ---- record() writes to all three buckets --------------------------------

  def test_record_writes_processed_counter_in_minute_bucket
    Wurk::Metrics::History.record(@klass, 42, success: true, at: @at)

    minute = Wurk::Metrics::History.minute_key(@at)
    val = Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|p") }

    assert_equal '1', val
  end

  def test_record_writes_failed_counter_when_unsuccessful
    Wurk::Metrics::History.record(@klass, 8, success: false, at: @at)

    minute = Wurk::Metrics::History.minute_key(@at)
    val = Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|f") }

    assert_equal '1', val
  end

  def test_record_accumulates_ms_across_success_and_failure
    Wurk::Metrics::History.record(@klass, 10, success: true, at: @at)
    Wurk::Metrics::History.record(@klass, 25, success: false, at: @at)

    minute = Wurk::Metrics::History.minute_key(@at)
    val = Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|ms") }

    assert_equal '35', val
  end

  def test_record_writes_rollup_bucket
    Wurk::Metrics::History.record(@klass, 15, success: true, at: @at)

    rollup = Wurk::Metrics::History.rollup_key(@at)
    val = Wurk.redis { |c| c.call('HGET', rollup, "#{@klass}|p") }

    assert_equal '1', val
  end

  # Regression: at minutes ending in 0 the minute and rollup keys coincide,
  # so record must write the shared field once (not twice → "2").
  def test_record_does_not_double_count_at_rollup_boundary
    at = ::Time.utc(2026, 5, 21, 14, 30, 0)
    minute = Wurk::Metrics::History.minute_key(at)
    Wurk::Metrics::History.record(@klass, 5, success: true, at: at)

    assert_equal minute, Wurk::Metrics::History.rollup_key(at), 'precondition: keys collide at x0 minutes'
    val = Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|p") }

    assert_equal '1', val
  ensure
    Wurk.redis { |c| c.call('HDEL', minute, "#{@klass}|p", "#{@klass}|f", "#{@klass}|ms") } if minute
  end

  def test_record_writes_hourly_bucket
    Wurk::Metrics::History.record(@klass, 20, success: true, at: @at)
    Wurk::Metrics::History.record(@klass, 30, success: false, at: @at)

    hour = Wurk::Metrics::History.hour_key(@klass, @at)
    p, f, ms = Wurk.redis { |c| c.call('HMGET', hour, 'p', 'f', 'ms') }

    assert_equal '1', p
    assert_equal '1', f
    assert_equal '50', ms
  end

  def test_record_sets_minute_ttl_to_mid_term
    Wurk::Metrics::History.record(@klass, 1, success: true, at: @at)

    ttl = Wurk.redis { |c| c.call('TTL', Wurk::Metrics::History.minute_key(@at)) }

    assert_operator ttl, :>, Wurk::Metrics::History::MID_TERM - 60
    assert_operator ttl, :<=, Wurk::Metrics::History::MID_TERM
  end

  def test_record_sets_rollup_ttl_to_short_term
    Wurk::Metrics::History.record(@klass, 1, success: true, at: @at)

    ttl = Wurk.redis { |c| c.call('TTL', Wurk::Metrics::History.rollup_key(@at)) }

    assert_operator ttl, :>, Wurk::Metrics::History::SHORT_TERM - 60
    assert_operator ttl, :<=, Wurk::Metrics::History::SHORT_TERM
  end

  def test_record_sets_hourly_ttl_to_mid_term
    Wurk::Metrics::History.record(@klass, 1, success: true, at: @at)

    ttl = Wurk.redis { |c| c.call('TTL', Wurk::Metrics::History.hour_key(@klass, @at)) }

    assert_operator ttl, :>, Wurk::Metrics::History::MID_TERM - 60
    assert_operator ttl, :<=, Wurk::Metrics::History::MID_TERM
  end

  def test_record_ignores_blank_klass
    Wurk::Metrics::History.record(nil, 1, success: true, at: @at)
    Wurk::Metrics::History.record('', 1, success: true, at: @at)

    minute = Wurk::Metrics::History.minute_key(@at)

    refute(Wurk.redis { |c| c.call('EXISTS', minute) == 1 })
  end

  def test_record_clamps_negative_duration_to_zero
    Wurk::Metrics::History.record(@klass, -50, success: true, at: @at)

    minute = Wurk::Metrics::History.minute_key(@at)
    val = Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|ms") }

    assert_equal '0', val
  end

  # ---- middleware integration ---------------------------------------------

  def test_middleware_records_success_and_yields_return
    mw = build_middleware
    job = { 'class' => @klass }
    result = mw.call(nil, job, 'default') { :ok }

    assert_equal :ok, result
    minute = Wurk::Metrics::History.minute_key(::Time.now.utc)

    assert_equal('1', Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|p") })
  end

  # #100: History must be on the server chain by default — no host-app
  # initializer required.
  def test_auto_registered_on_server_chain
    assert Wurk.configuration.server_middleware.exists?(Wurk::Metrics::History)
  end

  # An app that also registers History in an initializer must not double-count:
  # Chain#add removes any existing entry for the klass before appending, so
  # re-adding replaces rather than duplicates.
  def test_re_adding_history_keeps_a_single_entry
    chain = Wurk::Configuration.new.server_middleware
    chain.add(Wurk::Metrics::History)
    chain.add(Wurk::Metrics::History) # gem auto-registered, then app re-adds

    assert_equal(1, chain.entries.count { |e| e.klass == Wurk::Metrics::History })
  end

  # End-to-end through the default capsule's bound chain — exactly how the
  # Processor invokes it (lib/wurk/processor.rb:226). Running a job records the
  # minute bucket with no host-app initializer, because History is
  # auto-registered on boot. The record uses Time.now inside the middleware, so
  # accept either candidate minute to stay deterministic across a minute tick.
  def test_default_server_chain_records_without_initializer
    before = ::Time.now.utc
    Wurk.configuration.default_capsule.server_middleware.invoke(nil, { 'class' => @klass }, 'default') { :ok }

    assert recorded_processed_between?(before, ::Time.now.utc),
           'expected processed=1 in the minute bucket'
  end

  def test_middleware_records_failure_when_perform_raises
    mw = build_middleware
    job = { 'class' => @klass }
    assert_raises(::RuntimeError) do
      mw.call(nil, job, 'default') { raise 'boom' }
    end

    minute = Wurk::Metrics::History.minute_key(::Time.now.utc)

    assert_equal('1', Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|f") })
  end

  def test_middleware_swallows_redis_failure_post_perform
    broken_pool = Object.new
    def broken_pool.with(&)
      raise 'redis down'
    end

    cfg = Wurk::Configuration.new
    cfg.logger = Logger.new(IO::NULL)
    # Stub redis_pool on this throwaway capsule so the middleware reads our broken pool.
    cfg.default_capsule.instance_variable_set(:@redis_pool, broken_pool)
    mw = Wurk::Metrics::History.new
    mw.config = cfg

    result = mw.call(nil, { 'class' => @klass }, 'default') { :ok }

    assert_equal :ok, result
  end

  private

  def build_middleware
    mw = Wurk::Metrics::History.new
    mw.config = Wurk.configuration
    mw
  end

  # The middleware records at its own Time.now, so the bucket lands in the
  # minute of either `started_at` or `ended_at` (the window around the invoke).
  # True if the processed counter shows 1 in either candidate minute bucket.
  def recorded_processed_between?(started_at, ended_at)
    [started_at, ended_at].map { |t| Wurk::Metrics::History.minute_key(t) }.uniq.any? do |minute|
      Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|p") } == '1'
    end
  end
end
