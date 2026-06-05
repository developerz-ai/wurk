# frozen_string_literal: true

require_relative '../test_helper'

# Verifies the Sidekiq::* drop-in surface. Every constant and module function
# listed in docs/target/sidekiq-free.md §3 must resolve. Third-party gems
# (sidekiq-cron, sidekiq-unique-jobs, sidekiq-status, sidekiq-failures, …)
# load against this surface unchanged.
class CompatAliasesTest < Wurk::Test::UnitCase
  parallelize_me!

  STATE_MUTEX = Mutex.new

  # --- version stamps ----------------------------------------------------

  def test_name
    assert_equal 'Sidekiq', Sidekiq::NAME
  end

  def test_version
    assert_equal '8.1.5', Sidekiq::VERSION
  end

  def test_major
    assert_equal 8, Sidekiq::MAJOR
  end

  def test_license_defined
    assert_kind_of String, Sidekiq::LICENSE
  end

  # --- pro/ent sentinels -------------------------------------------------

  def test_pro_sentinel_defined
    assert(defined?(Sidekiq::Pro))
    assert_kind_of Module, Sidekiq::Pro
  end

  # A Pro app's `mount Sidekiq::Pro::Web` must drop in unchanged — it's the
  # same dashboard as Sidekiq::Web here.
  def test_pro_web_aliases_the_dashboard
    assert_same Wurk::Web, Sidekiq::Pro::Web
    assert_same Sidekiq::Web, Sidekiq::Pro::Web
  end

  def test_enterprise_sentinel_defined
    assert(defined?(Sidekiq::Enterprise))
    assert_kind_of Module, Sidekiq::Enterprise
  end

  # Wurk ships Pro+Ent features in the free gem but reports false from the
  # gates so third-party gems don't branch into paid-only quirks.
  # Spec: docs/target/sidekiq-free.md §32.
  def test_pro_predicate_false
    refute_predicate Sidekiq, :pro?
  end

  def test_ent_predicate_false
    refute_predicate Sidekiq, :ent?
  end

  # --- class aliases -----------------------------------------------------

  def test_basic_fetch_alias
    assert_same Wurk::Fetcher::Reliable, Sidekiq::BasicFetch
  end

  def test_batch_alias
    assert_same Wurk::Batch, Sidekiq::Batch
  end

  def test_batch_set_alias
    assert_same Wurk::BatchSet, Sidekiq::BatchSet
  end

  def test_capsule_alias
    assert_same Wurk::Capsule, Sidekiq::Capsule
  end

  def test_client_alias
    assert_same Wurk::Client, Sidekiq::Client
  end

  def test_component_alias
    assert_same Wurk::Component, Sidekiq::Component
  end

  def test_config_alias
    assert_same Wurk::Configuration, Sidekiq::Config
  end

  def test_context_alias
    assert_same Wurk::Context, Sidekiq::Context
  end

  def test_cron_alias
    assert_same Wurk::Cron, Sidekiq::Cron
  end

  def test_metrics_alias
    assert_same Wurk::Metrics, Sidekiq::Metrics
    assert_same Wurk::Metrics::Rollup, Sidekiq::Metrics::Rollup
  end

  def test_dead_set_alias
    assert_same Wurk::DeadSet, Sidekiq::DeadSet
  end

  def test_iterable_job_alias
    assert_same Wurk::IterableJob, Sidekiq::IterableJob
  end

  def test_job_alias
    assert_same Wurk::Job, Sidekiq::Job
  end

  # Sidekiq 7+ documents the per-call option carrier under `Sidekiq::Job::Setter`.
  # `Sidekiq::Job = Wurk::Job`, so the constant must resolve through the Job
  # namespace too — not just `Sidekiq::Worker::Setter`. See issue #96.
  def test_job_setter_alias
    assert_same Wurk::Worker::Setter, Sidekiq::Job::Setter
    assert_same Sidekiq::Worker::Setter, Sidekiq::Job::Setter
  end

  def test_job_logger_alias
    assert_same Wurk::JobLogger, Sidekiq::JobLogger
  end

  def test_job_record_alias
    assert_same Wurk::JobRecord, Sidekiq::JobRecord
  end

  def test_job_retry_alias
    assert_same Wurk::JobRetry, Sidekiq::JobRetry
  end

  def test_job_util_alias
    assert_same Wurk::JobUtil, Sidekiq::JobUtil
  end

  def test_keys_alias
    assert_same Wurk::Keys, Sidekiq::Keys
  end

  def test_launcher_alias
    assert_same Wurk::Launcher, Sidekiq::Launcher
  end

  def test_limiter_alias
    assert_same Wurk::Limiter, Sidekiq::Limiter
  end

  def test_logger_alias
    assert_same Wurk::Logger, Sidekiq::Logger
  end

  def test_manager_alias
    assert_same Wurk::Manager, Sidekiq::Manager
  end

  def test_middleware_module_alias
    assert_same Wurk::Middleware, Sidekiq::Middleware
  end

  def test_middleware_chain_alias
    assert_same Wurk::Middleware::Chain, Sidekiq::Middleware::Chain
  end

  def test_server_middleware_alias
    assert_same Wurk::Middleware::ServerMiddleware, Sidekiq::ServerMiddleware
  end

  def test_client_middleware_alias
    assert_same Wurk::Middleware::ClientMiddleware, Sidekiq::ClientMiddleware
  end

  def test_process_alias
    assert_same Wurk::Process, Sidekiq::Process
  end

  def test_process_set_alias
    assert_same Wurk::ProcessSet, Sidekiq::ProcessSet
  end

  def test_processor_alias
    assert_same Wurk::Processor, Sidekiq::Processor
  end

  def test_queue_alias
    assert_same Wurk::Queue, Sidekiq::Queue
  end

  def test_retry_set_alias
    assert_same Wurk::RetrySet, Sidekiq::RetrySet
  end

  def test_scheduled_alias
    assert_same Wurk::Scheduled, Sidekiq::Scheduled
  end

  def test_scheduled_set_alias
    assert_same Wurk::ScheduledSet, Sidekiq::ScheduledSet
  end

  def test_shutdown_alias
    assert_same Wurk::Shutdown, Sidekiq::Shutdown
  end

  def test_stats_alias
    assert_same Wurk::Stats, Sidekiq::Stats
  end

  def test_work_alias
    assert_same Wurk::Work, Sidekiq::Work
  end

  def test_worker_alias
    assert_same Wurk::Worker, Sidekiq::Worker
  end

  def test_workers_deprecated_alias
    assert_same Wurk::WorkSet, Sidekiq::Workers
  end

  def test_work_set_alias
    assert_same Wurk::WorkSet, Sidekiq::WorkSet
  end

  # --- module functions --------------------------------------------------

  def test_configure_server_yields_when_server
    STATE_MUTEX.synchronize do
      Wurk.configuration[:server] = true
      seen = nil
      Sidekiq.configure_server { |c| seen = c }

      assert_same Wurk.configuration, seen
    ensure
      Wurk.configuration[:server] = false
    end
  end

  def test_configure_client_yields_when_not_server
    STATE_MUTEX.synchronize do
      seen = nil
      Sidekiq.configure_client { |c| seen = c }

      assert_same Wurk.configuration, seen
    end
  end

  def test_configure_embed_always_yields
    STATE_MUTEX.synchronize do
      original_concurrency = Wurk.configuration.concurrency
      seen = nil
      Sidekiq.configure_embed { |c| seen = c }

      assert_same Wurk.configuration, seen
    ensure
      Wurk.configuration.concurrency = original_concurrency
    end
  end

  def test_configure_embed_returns_embedded_instance
    STATE_MUTEX.synchronize do
      original_concurrency = Wurk.configuration.concurrency
      embedded = Sidekiq.configure_embed { |_c| nil }

      assert_kind_of Wurk::Embedded, embedded
    ensure
      Wurk.configuration.concurrency = original_concurrency
    end
  end

  def test_configure_embed_defaults_concurrency_to_two
    STATE_MUTEX.synchronize do
      original_concurrency = Wurk.configuration.concurrency
      Sidekiq.configure_embed { |_c| nil }

      assert_equal 2, Wurk.configuration.concurrency
    ensure
      Wurk.configuration.concurrency = original_concurrency
    end
  end

  def test_embedded_alias
    assert_same Wurk::Embedded, Sidekiq::Embedded
  end

  def test_default_configuration
    assert_same Wurk.configuration, Sidekiq.default_configuration
  end

  def test_logger
    assert_same Wurk.logger, Sidekiq.logger
  end

  def test_redis_pool
    assert_same Wurk.redis_pool, Sidekiq.redis_pool
  end

  def test_redis_yields_connection
    seen = nil
    Sidekiq.redis { |c| seen = c }

    refute_nil seen
  end

  def test_dump_json_round_trips
    assert_equal '{"a":1}', Sidekiq.dump_json('a' => 1)
  end

  def test_load_json_round_trips
    assert_equal({ 'a' => 1 }, Sidekiq.load_json('{"a":1}'))
  end

  def test_default_job_options_reader
    assert_includes Sidekiq.default_job_options, 'queue'
  end

  def test_default_job_options_setter_merges
    STATE_MUTEX.synchronize do
      original = Wurk.default_job_options.dup
      Sidekiq.default_job_options = { 'retry' => 5 }

      assert_equal 5, Wurk.default_job_options['retry']
    ensure
      Wurk.instance_variable_set(:@default_job_options, original)
    end
  end

  def test_strict_args_setter
    STATE_MUTEX.synchronize do
      Sidekiq.strict_args!(:warn)

      assert_equal :warn, Wurk.strict_args_mode
    ensure
      Wurk.remove_instance_variable(:@strict_args_mode) if Wurk.instance_variable_defined?(:@strict_args_mode)
    end
  end

  def test_testing_bang_round_trip
    STATE_MUTEX.synchronize do
      seen = nil
      Sidekiq.testing!(:fake) { seen = Sidekiq.testing? }

      assert seen
      refute_predicate Sidekiq, :testing?
    end
  end

  def test_server_predicate_defaults_false
    refute_predicate Sidekiq, :server?
  end
end
