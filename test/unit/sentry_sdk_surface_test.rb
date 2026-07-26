# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/sentry'

# Runs Wurk::Sentry against the *real* SDK. The other Sentry suites drive a
# double, which can drift from the API it imitates — this one pins the seam:
# a real `Sentry.init`, a real scope, real events off a dummy transport.
class SentrySdkSurfaceTest < Wurk::Test::UnitCase
  parallelize_me!

  class Boom < StandardError; end

  # Required here, not at file scope: minitest-parallel_fork loads every test
  # file in the parent and only then forks per class, so a top-level require
  # would define `::Sentry` for every other worker — including the suites that
  # install a double under that name, and the ones asserting its absence.
  # sentry-ruby is a development-only dependency; skip if it isn't installed.
  def setup
    super
    require 'sentry-ruby'
  rescue LoadError
    skip 'sentry-ruby not installed'
  end

  def teardown
    ::Sentry.close if defined?(::Sentry) && ::Sentry.initialized?
  ensure
    super
  end

  # DummyTransport keeps every event in memory — no network, no background
  # worker, no flush on exit.
  def init_sentry!
    ::Sentry.init do |config|
      config.dsn = 'http://public@localhost/1'
      config.background_worker_threads = 0
      config.auto_session_tracking = false
      # No auto-instrumentation: the redis patch would wrap the same
      # redis-client this worker's Redis isolation runs through.
      config.enabled_patches = []
      config.transport.transport_class = ::Sentry::DummyTransport
      config.sdk_logger = ::Logger.new(IO::NULL) if config.respond_to?(:sdk_logger=)
    end
  end

  def events = ::Sentry.get_current_client.transport.events

  def job(overrides = {})
    { 'class' => 'MyJob', 'jid' => 'j1', 'queue' => 'critical', 'retry' => false,
      'args' => ['4111-1111-1111-1111'] }.merge(overrides)
  end

  def run_failing_job
    middleware = Wurk::Sentry::Middleware.new
    middleware.config = nil
    assert_raises(Boom) do
      middleware.call(nil, job, 'critical') { raise Boom, 'kaboom' }
    end
  end

  # =====================================================================
  # Inert until Sentry.init runs
  # =====================================================================

  def test_disabled_when_the_sdk_is_loaded_but_not_initialized
    refute_predicate Wurk::Sentry, :enabled?, 'a loaded-but-uninitialized SDK must not enable reporting'
  end

  def test_middleware_is_a_pass_through_before_init
    middleware = Wurk::Sentry::Middleware.new
    middleware.config = nil

    assert_equal :payload, middleware.call(nil, job, 'critical') { :payload }
  end

  def test_error_handler_is_a_no_op_before_init
    assert_nil Wurk::Sentry::ErrorHandler.new.call(Boom.new, { context: 'Error fetching job' })
  end

  # =====================================================================
  # Real events
  # =====================================================================

  def test_enabled_after_init
    init_sentry!

    assert_predicate Wurk::Sentry, :enabled?
  end

  def test_job_failure_produces_one_event
    init_sentry!
    run_failing_job

    assert_equal 1, events.size
  end

  def test_event_carries_the_wurk_transaction_name
    init_sentry!
    run_failing_job

    assert_equal 'Wurk/MyJob', events.first.transaction
  end

  def test_event_carries_the_queue_and_jid_tags
    init_sentry!
    run_failing_job

    assert_equal({ queue: 'critical', jid: 'j1' }, events.first.tags)
  end

  def test_event_carries_the_wurk_context_without_args
    init_sentry!
    run_failing_job

    refute_includes events.first.contexts[:wurk].keys, 'args'
  end

  def test_error_handler_event_carries_the_context_tag
    init_sentry!
    Wurk::Sentry::ErrorHandler.new.call(Boom.new('fetch'), { context: 'Error fetching job' })

    assert_equal({ wurk_context: 'Error fetching job' }, events.first.tags)
  end

  def test_error_handler_event_strips_job_args
    init_sentry!
    payload = { 'class' => 'MyJob', 'args' => ['4111-1111-1111-1111'] }
    Wurk::Sentry::ErrorHandler.new.call(Boom.new, { context: 'Invalid JSON', job: payload })

    assert_equal({ 'class' => 'MyJob' }, events.first.extra[:job])
  end

  def test_error_handler_skips_transport_noise_against_the_real_sdk
    init_sentry!
    Wurk::Sentry::ErrorHandler.new.call(RedisClient::ConnectionError.new('reset'), { context: 'Error fetching job' })

    assert_empty events
  end
end
