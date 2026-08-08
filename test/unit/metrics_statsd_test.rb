# frozen_string_literal: true

require_relative '../test_helper'

# Pins the Wurk::Metrics::Statsd contract: no-op when no client wired,
# emits prefixed metrics through the configured callable, supports the
# Pro per-job `options` proc + `dd_rate` override, and acts as a clean
# server middleware around `yield`.
#
# Mutates global Wurk.configuration.dogstatsd / Statsd.options. The class opts
# into the parallel runner per the project contract but holds the suite-wide
# `Wurk::Test::STATSD_MUTEX` around #run — required because other test classes
# (client_buffered, middleware_expiry, middleware_poison_pill) also rewrite
# Statsd singletons, and a per-class mutex doesn't protect against them.
class MetricsStatsdTest < Wurk::Test::UnitCase
  parallelize_me!

  def run(*args, &)
    Wurk::Test::STATSD_MUTEX.synchronize { super }
  end

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

  # --- client memo --------------------------------------------------------

  # The memo is tri-state: "unresolved" is distinct from a resolved nil, so an
  # unconfigured process stops re-reading config on every emit. Assigning
  # behind the writer's back is how a test can observe the cached nil at all.
  def test_client_memoizes_the_unconfigured_answer
    Wurk.configuration.dogstatsd = nil

    assert_nil Wurk::Metrics::Statsd.client

    Wurk.configuration.instance_variable_set(:@dogstatsd, FakeClient.new)

    assert_nil Wurk::Metrics::Statsd.client, 'unconfigured answer must be cached, not re-resolved per call'
  end

  def test_dogstatsd_assignment_drops_the_memo
    Wurk.configuration.dogstatsd = nil

    assert_nil Wurk::Metrics::Statsd.client

    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    assert_same fake, Wurk::Metrics::Statsd.client
  end

  # Swarm children call reset! after fork so they build their own socket
  # instead of inheriting the parent's (Swarm::ChildBoot).
  def test_reset_re_invokes_the_builder
    invocations = 0
    Wurk.configuration.dogstatsd = lambda {
      invocations += 1
      FakeClient.new
    }

    Wurk::Metrics::Statsd.client
    Wurk::Metrics::Statsd.reset!
    Wurk::Metrics::Statsd.client

    assert_equal 2, invocations
  end

  # Hot-path callers reach for the client directly to skip work; a builder that
  # blows up must degrade to "no client", never propagate into their caller.
  def test_safe_client_swallows_a_raising_builder
    Wurk.configuration.dogstatsd = -> { raise 'boom' }

    assert_raises(RuntimeError) { Wurk::Metrics::Statsd.client }
    assert_nil Wurk::Metrics::Statsd.safe_client
  end

  # --- #115: Pro drop-in statsd setup snippet (spec §9.1) -----------------

  def test_server_statsd_alias_and_verbatim_snippet
    require 'sidekiq/middleware/server/statsd'

    assert_same Wurk::Metrics::Statsd, Sidekiq::Middleware::Server::Statsd

    chain = Wurk::Middleware::Chain.new
    chain.add Sidekiq::Middleware::Server::Statsd
    Sidekiq::Middleware::Server::Statsd.options = ->(_w, _j, _q) { { tags: ['x'] } }

    assert chain.exists?(Wurk::Metrics::Statsd)
  end

  # --- #168: Pro batch statsd metrics (spec §9.3) -------------------------

  def test_batch_created_metric_emitted_on_first_flush
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    batch = Wurk::Batch.new
    batch.jobs { Wurk::Client.push('class' => 'NoOp', 'args' => [], 'queue' => 'sq') }

    assert_includes fake.calls.map { |c| c[1] }, 'sidekiq.batch.created'
  end

  def test_batch_duration_dist_metric_emitted_on_success
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    batch = Wurk::Batch.new
    batch.jobs { Wurk::Client.push('class' => 'NoOp', 'args' => [], 'queue' => 'sq') }
    Wurk::Batch::Callbacks.fire_success(batch.bid)

    dist = fake.calls.find { |c| c[0] == :distribution && c[1] == 'sidekiq.batch.duration_dist' }

    assert dist, "expected sidekiq.batch.duration_dist, got #{fake.calls.map { |c| c[1] }}"
    assert_operator dist[2], :>=, 0.0
  end

  def test_metric_names_get_sidekiq_prefix
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    Wurk::Metrics::Statsd.increment('jobs.poison', tags: ['class:X'])

    assert_equal :increment, fake.calls.first[0]
    assert_equal 'sidekiq.jobs.poison', fake.calls.first[1]
    assert_equal ['class:X'], fake.calls.first[2][:tags]
  end

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

  # line 59 then: gauge returns nil with no client wired.
  def test_gauge_no_op_when_no_client_configured
    Wurk.configuration.dogstatsd = nil

    assert_nil Wurk::Metrics::Statsd.gauge('jobs.perform', 5.0)
  end

  # line 62 else: gauge with tags:nil must not set the :tags key.
  def test_gauge_omits_tags_when_nil
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    Wurk::Metrics::Statsd.gauge('jobs.perform', 5.0)

    refute_includes fake.calls.first[3].keys, :tags
  end

  # line 75 then: distribution returns nil with no client wired.
  def test_distribution_no_op_when_no_client_configured
    Wurk.configuration.dogstatsd = nil

    assert_nil Wurk::Metrics::Statsd.distribution('jobs.perform_dist', 5.0)
  end

  # line 78 else: distribution with tags:nil must not set the :tags key.
  def test_distribution_omits_tags_when_nil
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    Wurk::Metrics::Statsd.distribution('jobs.perform_dist', 5.0)

    refute_includes fake.calls.first[3].keys, :tags
  end

  # line 82 else: client lacks both distribution and histogram — emit nothing,
  # still return nil cleanly.
  def test_distribution_no_op_when_client_lacks_both_methods
    bare = Object.new
    bare.define_singleton_method(:respond_to?) { |_m, *| false }
    Wurk.configuration.dogstatsd = bare

    assert_nil Wurk::Metrics::Statsd.distribution('jobs.perform_dist', 5.0)
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

  # #394: InterruptHandler self-prepends, so Wurk::Job::Interrupted reaches this
  # middleware on its way out and used to emit `jobs.failure`. A cooperative
  # interruption is a success for classification purposes — same call as
  # Metrics::History's, so the two emitters can't disagree about one event.
  def test_call_emits_success_not_failure_when_interrupted
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake

    assert_raises(Wurk::Job::Interrupted) do
      build_middleware.call(nil, { 'class' => 'MyJob' }, 'q') { raise Wurk::Job::Interrupted }
    end

    metrics = fake.calls.map { |c| c[1] }

    assert_includes metrics, 'sidekiq.jobs.success'
    refute_includes metrics, 'sidekiq.jobs.failure'
    assert_includes metrics, 'sidekiq.jobs.perform'
    assert_includes metrics, 'sidekiq.jobs.perform_dist'
  end

  # Guard against the rescue widening: an IterableJob that resumes and finishes
  # emits a second `jobs.success`, so one interruption plus one completion is
  # 2 success / 0 failure — the counts Metrics::History books as 2 `p` / 0 `f`.
  def test_call_emits_a_second_success_when_the_interrupted_job_resumes
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake
    middleware = build_middleware

    assert_raises(Wurk::Job::Interrupted) do
      middleware.call(nil, { 'class' => 'MyJob' }, 'q') { raise Wurk::Job::Interrupted }
    end
    middleware.call(nil, { 'class' => 'MyJob' }, 'q') { :ok }

    metrics = fake.calls.map { |c| c[1] }

    assert_equal 2, metrics.count('sidekiq.jobs.success')
    assert_equal 0, metrics.count('sidekiq.jobs.failure')
  end

  def test_default_tags_include_worker_and_queue
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake
    build_middleware.call(nil, { 'class' => 'MyJob' }, 'critical') { :ok }
    count_call = fake.calls.find { |c| c[1] == 'sidekiq.jobs.count' }

    assert_equal ['worker:MyJob', 'queue:critical'], count_call[2][:tags]
  end

  # line 97 else: configuration object that doesn't respond to #dogstatsd
  # yields a nil client (clean no-op), without raising.
  def test_client_nil_when_configuration_lacks_dogstatsd
    bare_config = Object.new
    prev = Wurk.instance_variable_get(:@configuration)
    Wurk.instance_variable_set(:@configuration, bare_config)
    Wurk::Metrics::Statsd.reset!

    assert_nil Wurk::Metrics::Statsd.client
  ensure
    Wurk.instance_variable_set(:@configuration, prev)
    Wurk::Metrics::Statsd.reset!
  end

  # line 167 else: options proc returning a non-Hash is ignored — defaults stand.
  def test_options_proc_non_hash_return_ignored
    fake = FakeClient.new
    Wurk.configuration.dogstatsd = fake
    Wurk::Metrics::Statsd.options = ->(_k, _j, _q) { :not_a_hash }

    build_middleware.call(nil, { 'class' => 'MyJob' }, 'critical') { :ok }
    count = fake.calls.find { |c| c[1] == 'sidekiq.jobs.count' }

    assert_equal ['worker:MyJob', 'queue:critical'], count[2][:tags]
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
