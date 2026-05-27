# frozen_string_literal: true

require_relative '../test_helper'

# Coverage for `expires_in` end-to-end:
#   * Wurk::JobUtil#stamp_expiry — client-side stamping of the absolute
#     `expiry` epoch-float on the payload at push.
#   * Wurk::Middleware::Expiry — server-side check immediately before perform,
#     drops the job (statsd + clean ack) when expired; no preemption mid-run.
#
# These run in isolation (no Redis, no chain) so the assertions pin the
# middleware contract directly. Chain composition (Batch ack still firing on
# expired job) is covered separately in middleware_chain_test.rb if needed.
class MiddlewareExpiryTest < Wurk::Test::UnitCase
  parallelize_me!

  # --- fakes ---------------------------------------------------------------

  class FakeConfig
    attr_reader :redis_pool, :logger

    def initialize
      @redis_pool = nil
      @logger = ::Logger.new(IO::NULL)
    end
  end

  # Capturing shim for Wurk::Metrics::Statsd.increment. The real method is a
  # `nil`-returning no-op (statsd client is plumbed in by a host integration);
  # we swap in a recorder for the duration of one test.
  module StatsdRecorder
    @calls = []

    class << self
      attr_reader :calls

      def increment(metric, tags: nil)
        @calls << [metric, tags]
        nil
      end

      def reset!
        @calls = []
      end
    end
  end

  # `Wurk::Metrics::Statsd.increment` is a process-global singleton method —
  # serialize against every other test class that rewrites it (metrics_statsd,
  # client_buffered, middleware_poison_pill).
  def with_statsd_recorder
    Wurk::Test::STATSD_MUTEX.synchronize do
      real = Wurk::Metrics::Statsd.method(:increment)
      Wurk::Metrics::Statsd.singleton_class.send(:define_method, :increment) do |metric, tags: nil|
        StatsdRecorder.increment(metric, tags: tags)
      end
      StatsdRecorder.reset!
      begin
        yield StatsdRecorder
      ensure
        Wurk::Metrics::Statsd.singleton_class.send(:define_method, :increment, real)
      end
    end
  end

  def build_middleware
    m = Wurk::Middleware::Expiry.new
    m.config = FakeConfig.new
    m
  end

  # Minitest 6 dropped minitest/mock, so we hand-roll a Time.now override.
  # Yields the pinned epoch-float; restores the original Time.now in ensure.
  def with_time_now(epoch_f)
    frozen = ::Time.at(epoch_f)
    sc = ::Time.singleton_class
    original = ::Time.method(:now)
    sc.define_method(:now) { frozen }
    begin
      yield frozen.to_f
    ensure
      sc.define_method(:now) { |*a, &b| original.call(*a, &b) }
    end
  end

  # =====================================================================
  # Middleware behavior
  # =====================================================================

  def test_yields_when_no_expiry_set
    yielded = false
    result = build_middleware.call(nil, { 'class' => 'X' }, 'q') do
      yielded = true
      :ok
    end

    assert yielded
    assert_equal :ok, result
  end

  def test_yields_when_expiry_in_future
    future = ::Time.now.to_f + 60
    yielded = false
    build_middleware.call(nil, { 'class' => 'X', 'expiry' => future }, 'q') { yielded = true }

    assert yielded
  end

  def test_skips_when_expiry_in_past
    past = ::Time.now.to_f - 60
    yielded = false
    build_middleware.call(nil, { 'class' => 'X', 'expiry' => past }, 'q') { yielded = true }

    refute yielded
  end

  def test_skip_returns_nil_not_raises
    past = ::Time.now.to_f - 60
    result = nil
    assert_silent do
      result = build_middleware.call(nil, { 'class' => 'X', 'expiry' => past }, 'q') { :body }
    end

    assert_nil result
  end

  # rubocop:disable Minitest/MultipleAssertions
  # One test pinning the entire statsd wire shape (count + metric + tags);
  # splitting would obscure the contract.
  def test_skip_emits_statsd_jobs_expired
    past = ::Time.now.to_f - 60
    with_statsd_recorder do |recorder|
      build_middleware.call(nil, { 'class' => 'MyJob', 'expiry' => past }, 'q') { flunk 'must not yield' }

      assert_equal 1, recorder.calls.size
      metric, tags = recorder.calls.first

      assert_equal 'jobs.expired', metric
      assert_equal ['class:MyJob'], tags
    end
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_no_statsd_call_on_non_expired_job
    future = ::Time.now.to_f + 60
    with_statsd_recorder do |recorder|
      build_middleware.call(nil, { 'class' => 'X', 'expiry' => future }, 'q') { :ok }

      assert_empty recorder.calls
    end
  end

  def test_no_statsd_call_when_no_expiry
    with_statsd_recorder do |recorder|
      build_middleware.call(nil, { 'class' => 'X' }, 'q') { :ok }

      assert_empty recorder.calls
    end
  end

  # The EXPIRED counter is a process-global singleton. Serialize against
  # LauncherTest's flush_stats tests which also reset/incr it.
  def test_skip_bumps_processor_expired_counter
    Wurk::Test::PROCESSOR_COUNTER_MUTEX.synchronize do
      Wurk::Processor::EXPIRED.reset
      past = ::Time.now.to_f - 60
      build_middleware.call(nil, { 'class' => 'X', 'expiry' => past }, 'q') { flunk 'must not yield' }

      assert_equal 1, Wurk::Processor::EXPIRED.reset
    end
  end

  def test_does_not_bump_expired_counter_on_yield
    Wurk::Test::PROCESSOR_COUNTER_MUTEX.synchronize do
      Wurk::Processor::EXPIRED.reset
      future = ::Time.now.to_f + 60
      build_middleware.call(nil, { 'class' => 'X', 'expiry' => future }, 'q') { :ok }

      assert_equal 0, Wurk::Processor::EXPIRED.reset
    end
  end

  def test_expiry_at_exactly_now_does_not_skip
    # Strict `>` per spec §7: equal timestamps aren't expired yet.
    # Minitest 6 dropped `Time.stub`; hand-rolled override pins Time.now
    # so `expiry == now` deterministically (no narrow real-clock window).
    yielded = false
    with_time_now(1_700_000_000.0) do |frozen|
      build_middleware.call(nil, { 'class' => 'X', 'expiry' => frozen }, 'q') { yielded = true }
    end

    assert yielded, 'expiry equal to now must not skip'
  end

  def test_coerces_string_expiry_via_to_f
    # JSON round-trips numbers to Float, but some callers (cron, retries) may
    # send a String. to_f keeps the middleware tolerant.
    past = (::Time.now.to_f - 60).to_s
    yielded = false
    build_middleware.call(nil, { 'class' => 'X', 'expiry' => past }, 'q') { yielded = true }

    refute yielded
  end

  def test_does_not_preempt_during_perform
    # Once the block starts running, an expiry that elapses mid-perform must
    # not interrupt — middleware only checks before yield.
    expiry = ::Time.now.to_f + 0.05
    completed = false
    build_middleware.call(nil, { 'class' => 'X', 'expiry' => expiry }, 'q') do
      sleep(0.1)
      completed = true
    end

    assert completed, 'in-flight perform must finish even when expiry passes mid-run'
  end

  def test_module_inclusion
    assert_includes Wurk::Middleware::Expiry.ancestors, Wurk::Middleware::ServerMiddleware
  end

  def test_auto_registered_on_default_server_chain
    assert Wurk.configuration.server_middleware.exists?(Wurk::Middleware::Expiry)
  end

  def test_registered_after_batch_server_middleware
    chain = Wurk.configuration.server_middleware
    entries = chain.entries.map(&:klass)
    batch_idx = entries.index(Wurk::Batch::ServerMiddleware)
    expiry_idx = entries.index(Wurk::Middleware::Expiry)

    refute_nil batch_idx, 'Batch::ServerMiddleware must be registered'
    refute_nil expiry_idx, 'Expiry must be registered'
    assert_operator expiry_idx, :>, batch_idx, 'Expiry must follow Batch so batch ack_success still fires on skip'
  end

  # =====================================================================
  # Client-side stamping (JobUtil#stamp_expiry)
  # =====================================================================

  # A tiny harness exposing JobUtil's private finalize so we can pin the
  # stamping contract without booting the full client + Redis stack.
  class Stamper
    include Wurk::JobUtil

    def stamp(item)
      finalize(item)
    end
  end

  def test_client_stamps_absolute_expiry_from_expires_in
    created_at_ms = 1_700_000_000_000
    item = { 'created_at' => created_at_ms, 'expires_in' => 3600, 'class' => 'X', 'args' => [] }
    Stamper.new.stamp(item)

    assert_in_delta((created_at_ms / 1000.0) + 3600, item['expiry'], 0.001)
  end

  def test_client_does_not_overwrite_caller_supplied_expiry
    item = {
      'created_at' => 1_700_000_000_000,
      'expires_in' => 3600,
      'expiry' => 42.0,
      'class' => 'X',
      'args' => []
    }
    Stamper.new.stamp(item)

    assert_in_delta 42.0, item['expiry'], 0.001
  end

  def test_client_no_op_when_expires_in_missing
    item = { 'created_at' => 1_700_000_000_000, 'class' => 'X', 'args' => [] }
    Stamper.new.stamp(item)

    refute item.key?('expiry')
  end

  def test_client_accepts_float_duration
    created_at_ms = 1_700_000_000_000
    item = { 'created_at' => created_at_ms, 'expires_in' => 1.5, 'class' => 'X', 'args' => [] }
    Stamper.new.stamp(item)

    assert_in_delta((created_at_ms / 1000.0) + 1.5, item['expiry'], 0.001)
  end

  def test_client_skips_when_duration_does_not_respond_to_to_f
    weird = Object.new
    item = { 'created_at' => 1_700_000_000_000, 'expires_in' => weird, 'class' => 'X', 'args' => [] }
    Stamper.new.stamp(item)

    refute item.key?('expiry')
  end

  # =====================================================================
  # Integration: Worker.sidekiq_options(expires_in:) flows to payload
  # =====================================================================

  def test_worker_sidekiq_options_carries_expires_in
    klass = Class.new do
      include Wurk::Worker

      sidekiq_options expires_in: 600
      def perform; end
    end

    assert_equal 600, klass.get_sidekiq_options['expires_in']
  end

  def test_client_push_stamps_expiry_from_class_sidekiq_options
    with_expiry_job(3600) do |klass, queue, pool|
      before_s = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
      Wurk::Client.new.push('class' => klass, 'args' => [], 'queue' => queue)
      after_s = ::Process.clock_gettime(::Process::CLOCK_REALTIME)

      expiry = fetch_pushed_expiry(pool, queue)

      assert_expiry_in_window(expiry, before_s, after_s, 3600)
    end
  end

  private

  def with_expiry_job(duration)
    klass_name = "ExpiryJob_#{Process.pid}_#{object_id}"
    klass = Class.new do
      include Wurk::Worker

      sidekiq_options expires_in: duration
      def perform; end
    end
    Object.const_set(klass_name, klass)
    queue = "q-#{Process.pid}-#{object_id}"
    pool  = Wurk.configuration.redis_pool
    begin
      yield klass, queue, pool
    ensure
      pool.with do |c|
        c.call('DEL', "queue:#{queue}")
        c.call('SREM', 'queues', queue)
      end
      Object.send(:remove_const, klass_name) if Object.const_defined?(klass_name)
    end
  end

  def fetch_pushed_expiry(pool, queue)
    raw = pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, -1) }.first

    refute_nil raw, 'expected a payload in the test queue'
    JSON.parse(raw)['expiry']
  end

  def assert_expiry_in_window(expiry, before_s, after_s, duration)
    refute_nil expiry, 'expiry must be stamped onto the wire payload'
    assert_operator expiry, :>=, before_s + duration - 0.01
    assert_operator expiry, :<=, after_s  + duration + 0.01
  end
end
