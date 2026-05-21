# frozen_string_literal: true

require_relative '../test_helper'

# Pins the Wurk::Metrics::Statsd contract: no-op when no client wired,
# emits prefixed metrics through the configured callable, supports the
# Pro per-job `options` proc + `dd_rate` override, and acts as a clean
# server middleware around `yield`.
#
# Tests mutate global Wurk.configuration.dogstatsd / Statsd.options, so the
# class can't be parallelized — `Statsd.reset!` runs between tests and the
# absence of `parallelize_me!` keeps execution serial within the file.
class MetricsStatsdTest < Wurk::Test::UnitCase
  # In-memory client that records every call. Mirrors the surface
  # Wurk::Metrics::Statsd reaches for: increment / gauge / distribution.
  class FakeClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def increment(metric, **opts)
      @calls << [:increment, metric, opts]
    end

    def gauge(metric, value, **opts)
      @calls << [:gauge, metric, value, opts]
    end

    def distribution(metric, value, **opts)
      @calls << [:distribution, metric, value, opts]
    end
  end

  # Mirror without #distribution so the fallback path (histogram) is exercised.
  class StatsdOnlyClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def increment(metric, **opts)
      @calls << [:increment, metric, opts]
    end

    def gauge(metric, value, **opts)
      @calls << [:gauge, metric, value, opts]
    end

    def histogram(metric, value, **opts)
      @calls << [:histogram, metric, value, opts]
    end
  end

  def setup
    super
    @prev_builder = Wurk.configuration.dogstatsd
    @prev_options = Wurk::Metrics::Statsd.options
    Wurk::Metrics::Statsd.reset!
  end

  def teardown
    Wurk.configuration.dogstatsd = @prev_builder
    Wurk::Metrics::Statsd.options = @prev_options
    Wurk::Metrics::Statsd.reset!
  ensure
    super
  end

  # --- client wiring ------------------------------------------------------

  def test_increment_no_op_when_no_client_configured
    Wurk.configuration.dogstatsd = nil

    assert_nil Wurk::Metrics::Statsd.increment('jobs.poison')
  end

  def test_increment_invokes_configured_proc_once
    invocations = 0
    Wurk.configuration.dogstatsd = lambda {
      invocations += 1
      FakeClient.new
    }

    Wurk::Metrics::Statsd.increment('jobs.poison')
    Wurk::Metrics::Statsd.increment('jobs.poison')

    assert_equal 1, invocations, 'dogstatsd builder must be invoked exactly once per process'
  end

  def test_increment_accepts_non_callable_client
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    Wurk::Metrics::Statsd.increment('jobs.poison')

    assert_equal 1, fake.calls.size
  end

  # rubocop:disable Metrics/AbcSize
  def test_metric_names_get_sidekiq_prefix
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    Wurk::Metrics::Statsd.increment('jobs.poison', tags: ['class:X'])

    assert_equal :increment, fake.calls.first[0]
    assert_equal 'sidekiq.jobs.poison', fake.calls.first[1]
    assert_equal ['class:X'], fake.calls.first[2][:tags]
  end
  # rubocop:enable Metrics/AbcSize

  def test_increment_swallows_client_errors
    boom = Object.new
    boom.define_singleton_method(:increment) { |*_, **_| raise 'boom' }
    Wurk.configuration.dogstatsd = boom

    assert_silent { Wurk::Metrics::Statsd.increment('jobs.poison') }
  end

  def test_distribution_falls_back_to_histogram
    fake = StatsdOnlyClient.new
    Wurk.configuration.dogstatsd = fake

    Wurk::Metrics::Statsd.distribution('jobs.perform_dist', 12.5, tags: ['queue:x'])

    assert_equal :histogram, fake.calls.first[0]
    assert_equal 'sidekiq.jobs.perform_dist', fake.calls.first[1]
    assert_in_delta 12.5, fake.calls.first[2], 0.0001
  end

  def test_sample_rate_omitted_when_default
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    Wurk::Metrics::Statsd.increment('jobs.count', tags: ['x:1'])

    refute_includes fake.calls.first[2].keys, :sample_rate
  end

  def test_sample_rate_passed_through_when_overridden
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    Wurk::Metrics::Statsd.increment('jobs.count', tags: ['x:1'], sample_rate: 0.5)

    assert_in_delta 0.5, fake.calls.first[2][:sample_rate], 0.0001
  end

  # --- server middleware behavior ----------------------------------------

  def test_call_yields_when_no_client
    Wurk.configuration.dogstatsd = nil
    middleware = build_middleware
    yielded = false
    middleware.call(nil, { 'class' => 'X' }, 'default') { yielded = true }

    assert yielded
  end

  # rubocop:disable Minitest/MultipleAssertions
  def test_call_emits_count_success_perform_perform_dist_on_success
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    build_middleware.call(nil, { 'class' => 'MyJob' }, 'critical') { :ok }

    metrics = fake.calls.map { |c| c[1] }

    assert_includes metrics, 'sidekiq.jobs.count'
    assert_includes metrics, 'sidekiq.jobs.success'
    assert_includes metrics, 'sidekiq.jobs.perform'
    assert_includes metrics, 'sidekiq.jobs.perform_dist'
    refute_includes metrics, 'sidekiq.jobs.failure'
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_call_emits_failure_on_raise_and_rebubbles
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    assert_raises(RuntimeError) do
      build_middleware.call(nil, { 'class' => 'MyJob' }, 'q') { raise 'boom' }
    end

    metrics = fake.calls.map { |c| c[1] }

    assert_includes metrics, 'sidekiq.jobs.failure'
    refute_includes metrics, 'sidekiq.jobs.success'
  end

  def test_default_tags_include_worker_and_queue
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake
    build_middleware.call(nil, { 'class' => 'MyJob' }, 'critical') { :ok }
    count_call = fake.calls.find { |c| c[1] == 'sidekiq.jobs.count' }

    assert_equal ['worker:MyJob', 'queue:critical'], count_call[2][:tags]
  end

  def test_options_proc_overrides_tags
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake
    Wurk::Metrics::Statsd.options = ->(klass, _job, queue) { { tags: ["override:#{klass}:#{queue}"] } }

    build_middleware.call(nil, { 'class' => 'MyJob' }, 'q') { :ok }
    count = fake.calls.find { |c| c[1] == 'sidekiq.jobs.count' }

    assert_equal ['override:MyJob:q'], count[2][:tags]
  end

  def test_options_proc_sets_sample_rate
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake
    Wurk::Metrics::Statsd.options = ->(_k, _j, _q) { { sample_rate: 0.25 } }

    build_middleware.call(nil, { 'class' => 'MyJob' }, 'q') { :ok }
    count = fake.calls.find { |c| c[1] == 'sidekiq.jobs.count' }

    assert_in_delta 0.25, count[2][:sample_rate], 0.0001
  end

  def test_dd_rate_on_job_overrides_options_proc
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake
    Wurk::Metrics::Statsd.options = ->(_k, _j, _q) { { sample_rate: 0.25 } }

    build_middleware.call(nil, { 'class' => 'MyJob', 'dd_rate' => 0.1 }, 'q') { :ok }
    count = fake.calls.find { |c| c[1] == 'sidekiq.jobs.count' }

    assert_in_delta 0.1, count[2][:sample_rate], 0.0001
  end

  def test_module_inclusion
    assert_includes Wurk::Metrics::Statsd.ancestors, Wurk::Middleware::ServerMiddleware
  end

  def test_perform_gauge_is_milliseconds
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    build_middleware.call(nil, { 'class' => 'MyJob' }, 'q') { sleep(0.01) }
    perform = fake.calls.find { |c| c[0] == :gauge && c[1] == 'sidekiq.jobs.perform' }

    refute_nil perform
    assert_operator perform[2], :>=, 8.0, 'gauge must be in milliseconds'
  end

  private

  def build_middleware
    middleware = Wurk::Metrics::Statsd.new
    middleware.config = FakeConfig.new
    middleware
  end

  class FakeConfig
    def redis_pool = nil
    def logger = ::Logger.new(IO::NULL)
  end
end
