# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/fake_sentry'
require 'wurk/sentry'

# Wurk::Sentry::Middleware — the half of the integration that sees job
# failures. Job failures never reach `config.error_handlers` (JobRetry#local
# swallows them behind `Handled`), so everything asserted here is the only
# path a job exception has to Sentry.
class SentryMiddlewareTest < Wurk::Test::UnitCase
  include SentryConstantSwap

  parallelize_me!

  class Boom < StandardError; end

  # Minimal stand-in for a Capsule/Configuration seam. Only `[]` matters —
  # RetryPolicy reads `config[:max_retries]` through it.
  class FakeConfig
    def initialize(options = {})
      @options = options
    end

    def [](key) = @options[key]
  end

  # A Capsule exposes its Configuration via `#config` and has no `[]` of its own.
  class FakeCapsule
    attr_reader :config

    def initialize(config) = @config = config
  end

  class RetryingWorker
    # Sidekiq's API name; the drop-in contract is not negotiable.
    def self.get_sidekiq_options = { 'retry' => true } # rubocop:disable Naming/AccessorMethodName
  end

  def build_middleware(config = FakeConfig.new)
    middleware = Wurk::Sentry::Middleware.new
    middleware.config = config
    middleware
  end

  def job(overrides = {})
    { 'class' => 'MyJob', 'jid' => 'abc123', 'queue' => 'critical', 'args' => %w[secret-token],
      'created_at' => 1_700_000_000_000, 'enqueued_at' => 1_700_000_000_500 }.merge(overrides)
  end

  # A payload on its last legs: default 25 attempts, 24 retries already done.
  def terminal_job(overrides = {}) = job({ 'retry' => true, 'retry_count' => 24 }.merge(overrides))

  def run_job(job_hash, config: FakeConfig.new, instance: nil, &)
    build_middleware(config).call(instance, job_hash, 'critical', &)
  end

  def assert_raises_boom(job_hash, **)
    assert_raises(Boom) { run_job(job_hash, **) { raise Boom, 'kaboom' } }
  end

  # =====================================================================
  # Scope
  # =====================================================================

  def test_sets_transaction_name_mirroring_sentry_sidekiq
    run_job(job) { :ok }

    assert_equal 'Wurk/MyJob', FakeSentry.last_scope.transaction_name
  end

  def test_transaction_source_is_task
    run_job(job) { :ok }

    assert_equal :task, FakeSentry.last_scope.transaction_source
  end

  def test_sets_queue_and_jid_tags
    run_job(job) { :ok }

    assert_equal({ queue: 'critical', jid: 'abc123' }, FakeSentry.last_scope.tags)
  end

  def test_queue_tag_falls_back_to_the_fetched_queue
    run_job(job('queue' => nil)) { :ok }

    assert_equal 'critical', FakeSentry.last_scope.tags[:queue]
  end

  def test_sets_the_wurk_context_block
    run_job(job('retry_count' => 3)) { :ok }

    assert_equal(
      { 'class' => 'MyJob', 'jid' => 'abc123', 'queue' => 'critical', 'retry_count' => 3,
        'created_at' => 1_700_000_000_000, 'enqueued_at' => 1_700_000_000_500 },
      FakeSentry.last_scope.contexts[:wurk]
    )
  end

  def test_context_never_includes_args
    run_job(job) { :ok }

    refute_includes FakeSentry.last_scope.contexts[:wurk].keys, 'args'
  end

  def test_clears_breadcrumbs_so_jobs_do_not_inherit_each_others_trail
    run_job(job) { :ok }

    assert FakeSentry.last_scope.breadcrumbs_cleared
  end

  def test_clones_the_hub_into_the_processor_thread
    run_job(job) { :ok }

    assert_equal 1, FakeSentry.hub_clones
  end

  def test_returns_the_block_value
    assert_equal :payload, run_job(job) { :payload }
  end

  # =====================================================================
  # Capture policy — terminal failures only
  # =====================================================================

  def test_captures_the_terminal_failure
    assert_raises_boom(terminal_job)

    assert_equal 1, FakeSentry.captured.size
  end

  def test_captures_the_actual_exception
    assert_raises_boom(terminal_job)

    assert_instance_of Boom, FakeSentry.captured_exceptions.first
  end

  # The exact boundary: JobRetry#bump_retry_count turns retry_count 23 into 24,
  # which is < 25 and reschedules; 24 becomes 25, which exhausts.
  def test_does_not_capture_one_attempt_before_the_last
    assert_raises_boom(job('retry' => true, 'retry_count' => 23))

    assert_empty FakeSentry.captured
  end

  def test_captures_on_the_last_attempt
    assert_raises_boom(job('retry' => true, 'retry_count' => 24))

    assert_equal 1, FakeSentry.captured.size
  end

  def test_does_not_capture_the_first_of_many_attempts
    assert_raises_boom(job('retry' => true))

    assert_empty FakeSentry.captured
  end

  def test_captures_immediately_when_retry_is_false
    assert_raises_boom(job('retry' => false))

    assert_equal 1, FakeSentry.captured.size
  end

  def test_captures_immediately_when_retry_is_zero
    assert_raises_boom(job('retry' => 0))

    assert_equal 1, FakeSentry.captured.size
  end

  def test_honors_an_integer_retry_budget
    assert_raises_boom(job('retry' => 3, 'retry_count' => 1))

    assert_empty FakeSentry.captured
  end

  def test_captures_at_the_integer_retry_budget_boundary
    assert_raises_boom(job('retry' => 3, 'retry_count' => 2))

    assert_equal 1, FakeSentry.captured.size
  end

  def test_honors_config_max_retries
    config = FakeConfig.new(max_retries: 2)

    assert_raises_boom(job('retry' => true, 'retry_count' => 1), config: config)

    assert_equal 1, FakeSentry.captured.size
  end

  def test_reads_max_retries_through_a_capsule
    config = FakeCapsule.new(FakeConfig.new(max_retries: 2))

    assert_raises_boom(job('retry' => true, 'retry_count' => 0), config: config)

    assert_empty FakeSentry.captured
  end

  def test_tolerates_a_config_without_options_access
    assert_raises_boom(terminal_job, config: Object.new)

    assert_equal 1, FakeSentry.captured.size
  end

  def test_tolerates_a_nil_config
    assert_raises_boom(terminal_job, config: nil)

    assert_equal 1, FakeSentry.captured.size
  end

  # =====================================================================
  # retry: nil — the worker class decides (mirrors JobRetry#local)
  # =====================================================================

  def test_falls_back_to_the_worker_class_retry_option
    payload = job.tap { |h| h.delete('retry') }

    assert_raises_boom(payload, instance: RetryingWorker.new)

    assert_empty FakeSentry.captured
  end

  def test_defaults_to_retryable_when_no_instance_is_available
    payload = job.tap { |h| h.delete('retry') }

    assert_raises_boom(payload)

    assert_empty FakeSentry.captured
  end

  # =====================================================================
  # retry_for — a wall-clock budget that supersedes the attempt count
  # =====================================================================

  def test_retry_for_is_not_terminal_before_the_budget_elapses
    failed_at = (Time.now.to_f * 1000).to_i

    assert_raises_boom(job('retry' => true, 'retry_count' => 40, 'retry_for' => 3600, 'failed_at' => failed_at))

    assert_empty FakeSentry.captured
  end

  def test_retry_for_is_terminal_once_the_budget_elapses
    failed_at = ((Time.now.to_f - 7200) * 1000).to_i

    assert_raises_boom(job('retry' => true, 'retry_count' => 1, 'retry_for' => 3600, 'failed_at' => failed_at))

    assert_equal 1, FakeSentry.captured.size
  end

  def test_retry_for_is_not_terminal_on_the_first_failure
    assert_raises_boom(job('retry' => true, 'retry_for' => 3600))

    assert_empty FakeSentry.captured
  end

  def test_retry_for_accepts_a_float_seconds_failed_at
    assert_raises_boom(job('retry' => true, 'retry_for' => 60, 'failed_at' => Time.now.to_f - 3600))

    assert_equal 1, FakeSentry.captured.size
  end

  # =====================================================================
  # Never reported
  # =====================================================================

  def test_does_not_capture_wurk_shutdown
    assert_raises(Wurk::Shutdown) { run_job(terminal_job) { raise Wurk::Shutdown } }

    assert_empty FakeSentry.captured
  end

  def test_does_not_capture_an_exception_caused_by_shutdown
    assert_raises(Boom) do
      run_job(terminal_job) do
        raise Wurk::Shutdown
      rescue Wurk::Shutdown
        raise Boom, 'swallowed the shutdown'
      end
    end

    assert_empty FakeSentry.captured
  end

  def test_does_not_capture_job_retry_handled
    assert_raises(Wurk::JobRetry::Handled) { run_job(terminal_job) { raise Wurk::JobRetry::Handled } }

    assert_empty FakeSentry.captured
  end

  def test_does_not_capture_job_retry_skip
    assert_raises(Wurk::JobRetry::Skip) { run_job(terminal_job) { raise Wurk::JobRetry::Skip } }

    assert_empty FakeSentry.captured
  end

  def test_survives_a_self_referential_cause_chain
    # A cause cycle must terminate the walk rather than recurse forever; the
    # exception is not a shutdown, so it is still reported.
    outer = Boom.new('outer')
    outer.define_singleton_method(:cause) { self }

    assert_raises(Boom) { run_job(terminal_job) { raise outer } }

    assert_equal 1, FakeSentry.captured.size
  end

  # =====================================================================
  # Re-raise contract — Wurk's retry pipeline owns the failure
  # =====================================================================

  def test_re_raises_on_a_terminal_failure
    assert_raises(Boom) { run_job(terminal_job) { raise Boom } }
  end

  def test_re_raises_on_a_retry_pending_failure
    assert_raises(Boom) { run_job(job('retry' => true)) { raise Boom } }
  end

  def test_re_raises_a_non_standard_error
    assert_raises(NotImplementedError) { run_job(terminal_job) { raise NotImplementedError } }
  end

  def test_captures_a_non_standard_error
    assert_raises(NotImplementedError) { run_job(terminal_job) { raise NotImplementedError } }

    assert_equal 1, FakeSentry.captured.size
  end

  # =====================================================================
  # Inert without Sentry
  # =====================================================================

  def test_no_op_when_sentry_is_not_initialized
    FakeSentry.initialized = false

    assert_raises(Boom) { run_job(terminal_job) { raise Boom } }

    assert_empty FakeSentry.captured
  end

  def test_does_not_touch_the_hub_when_sentry_is_not_initialized
    FakeSentry.initialized = false
    run_job(job) { :ok }

    assert_equal 0, FakeSentry.hub_clones
  end

  def test_still_yields_when_sentry_is_not_initialized
    FakeSentry.initialized = false

    assert_equal :payload, run_job(job) { :payload }
  end

  def test_no_op_when_sentry_ruby_is_absent
    Object.send(:remove_const, :Sentry)

    assert_raises(Boom) { run_job(terminal_job) { raise Boom } }
  end

  def test_yields_when_sentry_ruby_is_absent
    Object.send(:remove_const, :Sentry)

    assert_equal :payload, run_job(job) { :payload }
  end

  def test_is_server_middleware
    assert_includes Wurk::Sentry::Middleware.ancestors, Wurk::Middleware::ServerMiddleware
  end

  def test_not_registered_by_default
    refute Wurk.configuration.server_middleware.exists?(Wurk::Sentry::Middleware),
           'the integration must stay opt-in'
  end
end
