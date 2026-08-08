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
      drop_class_keys(c)
      drop_bucket_fields(c)
    end
  ensure
    super
  end

  # Hourly buckets are class-named, so SCAN reaches them.
  def drop_class_keys(conn)
    cursor = '0'
    loop do
      cursor, keys = conn.call('SCAN', cursor, 'MATCH', "*#{@klass}*", 'COUNT', 500)
      conn.call('DEL', *keys) unless keys.empty?
      break if cursor == '0'
    end
  end

  # Per-class fields live in shared, non-class-named minute buckets that SCAN
  # can't reach. HDEL every field this instance could have written from every
  # bucket it could have written to: the fixed @at bucket and its predecessor
  # (record tests) AND the current-time bucket (middleware tests record at
  # Time.now). Matched by prefix, because some tests suffix @klass to compare
  # two class names inside one bucket.
  def drop_bucket_fields(conn)
    keys = [@at, @at - 60, ::Time.now.utc].map { |t| Wurk::Metrics::History.minute_key(t) }
    keys.uniq.each do |key|
      mine = conn.call('HKEYS', key).select { |f| f.start_with?(@klass) }
      conn.call('HDEL', key, *mine) unless mine.empty?
    end
  end

  # ---- bucket key formatting -----------------------------------------------

  def test_minute_key_format
    assert_equal 'j|20260521|14:37', Wurk::Metrics::History.minute_key(@at)
  end

  def test_hour_key_format
    assert_equal 'FooJob-20260521-14', Wurk::Metrics::History.hour_key('FooJob', @at)
  end

  def test_minute_key_uses_utc
    local_time = ::Time.utc(2026, 5, 21, 23, 30) + 60

    assert_equal 'j|20260521|23:31', Wurk::Metrics::History.minute_key(local_time)
  end

  # ---- record() writes to both buckets -------------------------------------

  def test_record_writes_processed_counter_in_minute_bucket
    Wurk::Metrics::History.record(@klass, 42, success: true, at: @at)
    Wurk::Metrics::History.flush

    minute = Wurk::Metrics::History.minute_key(@at)
    val = Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|p") }

    assert_equal '1', val
  end

  def test_record_writes_failed_counter_when_unsuccessful
    Wurk::Metrics::History.record(@klass, 8, success: false, at: @at)
    Wurk::Metrics::History.flush

    minute = Wurk::Metrics::History.minute_key(@at)
    val = Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|f") }

    assert_equal '1', val
  end

  def test_record_accumulates_ms_across_success_and_failure
    Wurk::Metrics::History.record(@klass, 10, success: true, at: @at)
    Wurk::Metrics::History.record(@klass, 25, success: false, at: @at)
    Wurk::Metrics::History.flush

    minute = Wurk::Metrics::History.minute_key(@at)
    val = Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|ms") }

    assert_equal '35', val
  end

  # Regression (#metrics-double-count): we must NOT write a `H:m0` 10-minute
  # rollup. Its key would coincide with the minute-0 bucket, so a write at any
  # minute x1..x9 would inflate the minute-0 value into a decade total — which
  # the read side then sums alongside x1..x9 and double-counts. A minute x1..x9
  # write must touch its own minute key and nothing in that decade's x0 key.
  def test_record_does_not_write_a_ten_minute_rollup_bucket
    at = ::Time.utc(2026, 5, 21, 14, 37, 0)
    x0 = ::Time.utc(2026, 5, 21, 14, 30, 0)
    Wurk::Metrics::History.record(@klass, 5, success: true, at: at)
    Wurk::Metrics::History.flush

    x0_val = Wurk.redis { |c| c.call('HGET', Wurk::Metrics::History.minute_key(x0), "#{@klass}|p") }

    assert_nil x0_val, 'x1..x9 write must not bleed into the decade x0 bucket'
  ensure
    Wurk.redis { |c| c.call('HDEL', Wurk::Metrics::History.minute_key(x0), "#{@klass}|p") }
  end

  def test_record_writes_hourly_bucket
    Wurk::Metrics::History.record(@klass, 20, success: true, at: @at)
    Wurk::Metrics::History.record(@klass, 30, success: false, at: @at)
    Wurk::Metrics::History.flush

    hour = Wurk::Metrics::History.hour_key(@klass, @at)
    p, f, ms = Wurk.redis { |c| c.call('HMGET', hour, 'p', 'f', 'ms') }

    assert_equal '1', p
    assert_equal '1', f
    assert_equal '50', ms
  end

  def test_record_sets_minute_ttl_to_mid_term
    Wurk::Metrics::History.record(@klass, 1, success: true, at: @at)
    Wurk::Metrics::History.flush

    ttl = Wurk.redis { |c| c.call('TTL', Wurk::Metrics::History.minute_key(@at)) }

    assert_operator ttl, :>, Wurk::Metrics::History::MID_TERM - 60
    assert_operator ttl, :<=, Wurk::Metrics::History::MID_TERM
  end

  def test_record_sets_hourly_ttl_to_mid_term
    Wurk::Metrics::History.record(@klass, 1, success: true, at: @at)
    Wurk::Metrics::History.flush

    ttl = Wurk.redis { |c| c.call('TTL', Wurk::Metrics::History.hour_key(@klass, @at)) }

    assert_operator ttl, :>, Wurk::Metrics::History::MID_TERM - 60
    assert_operator ttl, :<=, Wurk::Metrics::History::MID_TERM
  end

  # Asserted on the fields a blank name would write, not on the bucket's
  # existence: the fixed-@at minute bucket is shared with every sibling in this
  # parallel class, so `EXISTS` on it answers "did anyone record this minute?"
  # — which is why it flaked. A blank name interpolates to a bare-pipe field
  # (`|p`) and to an hour key with an empty class segment; no real class name
  # reaches either.
  def test_record_ignores_blank_klass
    hour = Wurk::Metrics::History.hour_key('', @at)
    Wurk::Metrics::History.record(nil, 1, success: true, at: @at)
    Wurk::Metrics::History.record('', 1, success: true, at: @at)
    Wurk::Metrics::History.flush

    fields = Wurk.redis { |c| c.call('HKEYS', Wurk::Metrics::History.minute_key(@at)) }
    hour_exists = Wurk.redis { |c| c.call('EXISTS', hour) }

    assert_empty fields.grep(/\A\|/), 'a blank class must not write a bare-pipe field'
    assert_equal 0, hour_exists
  ensure
    Wurk.redis { |c| c.call('DEL', hour) }
  end

  def test_record_clamps_negative_duration_to_zero
    Wurk::Metrics::History.record(@klass, -50, success: true, at: @at)
    Wurk::Metrics::History.flush

    minute = Wurk::Metrics::History.minute_key(@at)
    val = Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|ms") }

    assert_equal '0', val
  end

  # ---- in-process accumulation --------------------------------------------

  # The behavior change slice 02 signed off on: nothing reaches Redis until a
  # flush. Everything below it is about that staying invisible on the wire.
  #
  # Proven on the wire rather than by reading the bucket back empty: `record`
  # folds into the process-wide accumulator, which the argless `flush` in the
  # parallel siblings of this class also drains, so an absent key would prove
  # only that no sibling flushed in the window. The two halves use different
  # class names for the same reason — the recorded one stays in that shared
  # accumulator, and counting it twice here is not a failure worth asserting on.
  def test_record_writes_nothing_until_the_flush
    spy = Wurk::Test::CommandSpy.new(Wurk.redis_pool)
    Thread.current[:wurk_capsule] = spy
    Wurk::Metrics::History.record("#{@klass}Recorded", 42, success: true, at: @at)

    assert_equal 0, spy.count

    fold { |acc| acc.add(nil, @klass, bucket, 42, true) }

    assert_equal('1', minute_fields(@klass)['p'])
  ensure
    Thread.current[:wurk_capsule] = nil
  end

  # The whole trade: N executions must leave Redis in exactly the state N
  # individual pipelines left it in — same keys, same fields, same values.
  # Anything else is a dashboard that reads differently after the swap.
  def test_flushed_state_is_identical_to_per_execution_writes
    batched = "#{@klass}Batched"
    per_job = "#{@klass}PerJob"

    fold { |acc| 10.times { |i| execution(acc, batched, i) } }
    10.times { |i| fold { |acc| execution(acc, per_job, i) } }

    assert_equal({ 'p' => '7', 'f' => '3', 'ms' => '82' }, hour_fields(per_job))
    assert_equal hour_fields(per_job), hour_fields(batched)
    assert_equal minute_fields(per_job), minute_fields(batched)
  end

  # `HINCRBY <field> 0` would materialize a counter the per-job path never
  # created, and the read side would start reporting an `f: 0` series for
  # classes that have never failed.
  def test_flush_omits_an_outcome_that_never_happened
    fold { |acc| 3.times { acc.add(nil, @klass, bucket, 5, true) } }

    assert_equal %w[ms p], hour_fields(@klass).keys.sort
    assert_equal %w[ms p], minute_fields(@klass).keys.sort
  end

  # Bucket attribution is decided when the job runs, not when the flush happens:
  # a drain carrying two minutes must land in two buckets, not in one.
  def test_flush_keeps_each_minute_in_its_own_bucket
    Wurk::Metrics::History.record(@klass, 5, success: true, at: @at)
    Wurk::Metrics::History.record(@klass, 5, success: true, at: @at - 60)
    Wurk::Metrics::History.flush

    %i[at prev].each do |which|
      key = Wurk::Metrics::History.minute_key(which == :at ? @at : @at - 60)

      assert_equal('1', Wurk.redis { |c| c.call('HGET', key, "#{@klass}|p") }, which.to_s)
    end
  end

  # 6 commands per (class, minute) per flush — the same 6 the hot path used to
  # send per job. 100 executions must not cost 600.
  def test_a_flush_costs_six_commands_regardless_of_execution_count
    spy = Wurk::Test::CommandSpy.new(Wurk.redis_pool)
    acc = Wurk::Metrics::Accumulator.new
    100.times { acc.add(spy, @klass, bucket, 5, true) }

    Wurk::Metrics::History.flush(acc)

    assert_equal 6, spy.count
  end

  # An idle worker must not spend a round trip every FLUSH_INTERVAL just to say
  # nothing happened.
  def test_flushing_an_empty_accumulator_costs_no_round_trip
    spy = Wurk::Test::CommandSpy.new(Wurk.redis_pool)
    Thread.current[:wurk_capsule] = spy

    assert_nil Wurk::Metrics::History.flush(Wurk::Metrics::Accumulator.new)
    assert_equal 0, spy.count
  ensure
    Thread.current[:wurk_capsule] = nil
  end

  # A transient Redis failure must not eat the window.
  def test_a_failed_flush_keeps_its_counts
    acc = flaky_accumulator

    assert_raises(RuntimeError) { Wurk::Metrics::History.flush(acc) }
    refute_predicate acc, :empty?
  end

  def test_the_tick_after_a_failed_flush_writes_the_counts_it_kept
    acc = flaky_accumulator
    assert_raises(RuntimeError) { Wurk::Metrics::History.flush(acc) }

    Wurk::Metrics::History.flush(acc)

    assert_equal('1', Wurk.redis { |c| c.call('HGET', Wurk::Metrics::History.minute_key(@at), "#{@klass}|p") })
  end

  # One pool's failure must not put the pools that already wrote back on the
  # retry list — HINCRBY would count them twice on the next tick.
  def test_a_failed_pool_does_not_drag_a_healthy_one_back_into_the_accumulator
    healthy = "#{@klass}Healthy"
    acc = Wurk::Metrics::Accumulator.new
    acc.add(nil, healthy, bucket, 1, true)
    acc.add(FlakyPool.new(Wurk.redis_pool), @klass, bucket, 1, true)

    assert_raises(RuntimeError) { Wurk::Metrics::History.flush(acc) }
    Wurk::Metrics::History.flush(acc)

    assert_equal({ 'p' => '1', 'ms' => '1' }, minute_fields(healthy))
  end

  # Raises once, then delegates — a Redis blip, not a dead server.
  class FlakyPool
    def initialize(pool)
      @pool = pool
      @failed = false
    end

    def with(&)
      return @pool.with(&) if @failed

      @failed = true
      raise 'redis down'
    end
  end

  # ---- middleware integration ---------------------------------------------

  def test_middleware_records_success_and_yields_return
    mw = build_middleware
    job = { 'class' => @klass }
    result = mw.call(nil, job, 'default') { :ok }
    Wurk::Metrics::History.flush

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
    Wurk::Metrics::History.flush

    assert recorded_processed_between?(before, ::Time.now.utc),
           'expected processed=1 in the minute bucket'
  end

  def test_middleware_records_failure_when_perform_raises
    mw = build_middleware
    job = { 'class' => @klass }
    assert_raises(::RuntimeError) do
      mw.call(nil, job, 'default') { raise 'boom' }
    end
    Wurk::Metrics::History.flush

    minute = Wurk::Metrics::History.minute_key(::Time.now.utc)

    assert_equal('1', Wurk.redis { |c| c.call('HGET', minute, "#{@klass}|f") })
  end

  # #394: InterruptHandler self-prepends, so Wurk::Job::Interrupted reaches this
  # middleware on its way out and used to be booked as a failure. It is neither
  # — the oracle books `p` + `ms` for a cooperative interruption and reserves
  # `f` for a real exception.
  def test_middleware_books_processed_not_failed_when_interrupted
    before = ::Time.now.utc
    assert_raises(Wurk::Job::Interrupted) do
      build_middleware.call(nil, { 'class' => @klass }, 'default') { raise Wurk::Job::Interrupted }
    end
    Wurk::Metrics::History.flush
    fields = middleware_fields(before, ::Time.now.utc)

    assert_equal '1', fields['p']
    assert_nil fields['f']
    assert fields.key?('ms'), 'expected the interrupted run to book its wall-clock into |ms'
  end

  # Guard against the rescue widening: an IterableJob that resumes and finishes
  # books a second `p`, so one interruption plus one completion is 2 `p` / 0 `f`.
  def test_middleware_books_a_second_processed_when_the_interrupted_job_resumes
    before = ::Time.now.utc
    mw = build_middleware
    assert_raises(Wurk::Job::Interrupted) do
      mw.call(nil, { 'class' => @klass }, 'default') { raise Wurk::Job::Interrupted }
    end
    mw.call(nil, { 'class' => @klass }, 'default') { :ok }
    Wurk::Metrics::History.flush
    fields = middleware_fields(before, ::Time.now.utc)

    assert_equal '2', fields['p']
    assert_nil fields['f']
  end

  # Recording is in-memory, so the failure the middleware has to swallow is no
  # longer a Redis blip (that moved to Flusher) but a payload it cannot key on —
  # here a `class` that isn't a String, which blows up on `#empty?`. The job's
  # return value must survive it and the error must reach the handler.
  def test_middleware_swallows_a_record_failure_post_perform
    reported = []
    cfg = Wurk::Configuration.new
    cfg.logger = Logger.new(IO::NULL)
    cfg.error_handlers << ->(ex, ctx, _cfg) { reported << [ex.class, ctx[:context]] }
    mw = Wurk::Metrics::History.new
    mw.config = cfg

    result = mw.call(nil, { 'class' => Object.new }, 'default') { :ok }

    assert_equal :ok, result
    assert_equal [[NoMethodError, 'Wurk::Metrics::History']], reported
  end

  private

  # The @at minute, as Accumulator keys it.
  def bucket
    @at.to_i / 60
  end

  # Folds executions into a throwaway accumulator and flushes it, so a test can
  # compare batched against per-execution writes without either one touching the
  # process-wide accumulator a parallel test is also using.
  def fold
    acc = Wurk::Metrics::Accumulator.new
    yield acc
    Wurk::Metrics::History.flush(acc)
  end

  # Execution `index` of a fixed ten: seven successes at 10ms, three failures
  # at 4ms. Same sequence whether it is folded into one flush or ten.
  def execution(acc, klass, index)
    index < 7 ? acc.add(nil, klass, bucket, 10, true) : acc.add(nil, klass, bucket, 4, false)
  end

  # One execution behind a pool that fails its first checkout — a Redis blip,
  # not a dead server.
  def flaky_accumulator
    Wurk::Metrics::Accumulator.new.tap { |acc| acc.add(FlakyPool.new(Wurk.redis_pool), @klass, bucket, 9, true) }
  end

  def hour_fields(klass)
    hgetall(Wurk::Metrics::History.hour_key(klass, @at))
  end

  # This class's fields out of the shared minute bucket, prefix stripped, so two
  # class names in the same bucket compare directly.
  def minute_fields(klass)
    hgetall(Wurk::Metrics::History.minute_key(@at))
      .select { |field, _| field.start_with?("#{klass}|") }
      .transform_keys { |field| field.split('|', 2).last }
  end

  # redis-client returns HGETALL as a Hash or a flat Array depending on version.
  def hgetall(key)
    raw = Wurk.redis { |c| c.call('HGETALL', key) }
    raw.is_a?(::Hash) ? raw : ::Hash[*raw]
  end

  def build_middleware
    mw = Wurk::Metrics::History.new
    mw.config = Wurk.configuration
    mw
  end

  # This class's fields out of whichever candidate minute bucket the middleware
  # landed in, prefix stripped. Merging both candidates is safe because @klass is
  # unique per test instance, so only one of them can hold its fields.
  def middleware_fields(started_at, ended_at)
    [started_at, ended_at].map { |t| Wurk::Metrics::History.minute_key(t) }.uniq.each_with_object({}) do |key, out|
      hgetall(key).each do |field, value|
        out[field.split('|', 2).last] = value if field.start_with?("#{@klass}|")
      end
    end
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
