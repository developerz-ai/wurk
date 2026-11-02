# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/fake_sentry'
require 'wurk/sentry'

# Wurk::Sentry::ErrorHandler — the `config.error_handlers` half of the
# integration: the fetch loop, the shutdown path, unparseable payloads, the
# retry machinery's own meta-errors, and the job failures Middleware never saw.
class SentryErrorHandlerTest < Wurk::Test::UnitCase
  include SentryConstantSwap

  parallelize_me!

  class Boom < StandardError; end

  def handler(**) = Wurk::Sentry::ErrorHandler.new(**)
  def h_shared = (@h_shared ||= handler)

  def redis_error
    # RedisClient::Error subclasses carry the same self-healing semantics as
    # the base class; the filter must walk the ancestry, not match exactly.
    RedisClient::ConnectionError.new('Connection reset by peer')
  end

  # =====================================================================
  # DeathHandler
  # =====================================================================

  def test_death_handler_reports_a_death_nothing_captured
    Wurk::Sentry::DeathHandler.new.call({ 'class' => 'J', 'queue' => 'q' }, Boom.new('poisoned'))

    assert_equal 1, FakeSentry.captured.size
    assert_equal({ wurk_context: 'dead' }, FakeSentry.captured.first[:options][:tags])
  end

  def test_death_handler_skips_the_failure_already_captured_on_this_thread
    error = Boom.new
    Wurk::Sentry::ErrorHandler.reported!(error)

    Wurk::Sentry::DeathHandler.new.call({ 'class' => 'J' }, error)

    assert_empty FakeSentry.captured
  end

  def test_death_handler_ignores_an_operator_kill_with_no_exception
    Wurk::Sentry::DeathHandler.new.call({ 'class' => 'J' }, nil)

    assert_empty FakeSentry.captured
  end

  # =====================================================================
  # Capture
  # =====================================================================

  def test_captures_a_fetch_loop_error
    handler.call(Boom.new('nope'), { context: 'Error fetching job' })

    assert_equal 1, FakeSentry.captured.size
  end

  def test_captures_the_actual_exception
    error = Boom.new('nope')
    handler.call(error, { context: 'Error fetching job' })

    assert_same error, FakeSentry.captured_exceptions.first
  end

  def test_tags_the_wurk_context_label
    handler.call(Boom.new, { context: '!shutdown' })

    assert_equal({ wurk_context: '!shutdown' }, FakeSentry.captured.first[:options][:tags])
  end

  def test_omits_the_tag_when_there_is_no_context_label
    handler.call(Boom.new, {})

    assert_empty FakeSentry.captured.first[:options][:tags]
  end

  def test_forwards_the_context_as_extra
    handler.call(Boom.new, { context: 'Error calling death handler', bid: 'b1' })

    assert_equal({ context: 'Error calling death handler', bid: 'b1' },
                 FakeSentry.captured.first[:options][:extra])
  end

  def test_tolerates_a_non_hash_context
    handler.call(Boom.new, 'just a string')

    assert_empty FakeSentry.captured.first[:options][:extra]
  end

  def test_defaults_the_context_to_empty
    handler.call(Boom.new)

    assert_equal 1, FakeSentry.captured.size
  end

  def test_accepts_the_sidekiq_three_argument_handler_signature
    handler.call(Boom.new, { context: 'x' }, Wurk.configuration)

    assert_equal 1, FakeSentry.captured.size
  end

  # =====================================================================
  # No args, ever
  # =====================================================================

  def test_strips_args_from_a_job_hash_in_the_context
    job = { 'class' => 'MyJob', 'jid' => 'j1', 'args' => ['4111-1111-1111-1111'] }
    handler.call(Boom.new, { context: 'Error calling retries_exhausted', job: job })

    refute_includes FakeSentry.captured.first[:options][:extra][:job].keys, 'args'
  end

  def test_keeps_the_rest_of_the_job_hash
    job = { 'class' => 'MyJob', 'jid' => 'j1', 'args' => ['secret'] }
    handler.call(Boom.new, { job: job })

    assert_equal({ 'class' => 'MyJob', 'jid' => 'j1' }, FakeSentry.captured.first[:options][:extra][:job])
  end

  def test_does_not_mutate_the_callers_job_hash
    job = { 'class' => 'MyJob', 'args' => ['secret'] }
    handler.call(Boom.new, { job: job })

    assert_equal ['secret'], job['args']
  end

  def test_drops_the_raw_payload_of_an_unparseable_job
    handler.call(JSON::ParserError.new('unexpected token'),
                 { context: 'Invalid JSON', jobstr: '{"args":["4111-1111-1111-1111"' })

    assert_equal({ context: 'Invalid JSON' }, FakeSentry.captured.first[:options][:extra])
  end

  # =====================================================================
  # Self-healing transport noise
  # =====================================================================

  def test_skips_redis_client_errors
    handler.call(redis_error, { context: 'Error fetching job' })

    assert_empty FakeSentry.captured
  end

  def test_skips_connection_pool_timeouts
    handler.call(ConnectionPool::TimeoutError.new('waited 5 sec'), { context: 'Error fetching job' })

    assert_empty FakeSentry.captured
  end

  def test_reports_transport_errors_when_filtering_is_disabled
    handler(filter_transport_errors: false).call(redis_error, { context: 'Error fetching job' })

    assert_equal 1, FakeSentry.captured.size
  end

  def test_filter_list_can_be_replaced
    custom = handler(filtered_error_classes: [Boom])
    custom.call(Boom.new, {})

    assert_empty FakeSentry.captured
  end

  def test_a_replaced_filter_list_no_longer_skips_the_defaults
    handler(filtered_error_classes: [Boom]).call(redis_error, {})

    assert_equal 1, FakeSentry.captured.size
  end

  def test_filter_list_can_be_extended
    classes = Wurk::Sentry::ErrorHandler::DEFAULT_FILTERED_ERROR_CLASSES + [Boom]
    extended = handler(filtered_error_classes: classes)
    extended.call(redis_error, {})
    extended.call(Boom.new, {})

    assert_empty FakeSentry.captured
  end

  def test_default_filter_list_is_the_connection_family_and_pool_timeouts
    assert_equal [RedisClient::ConnectionError, ConnectionPool::TimeoutError],
                 Wurk::Sentry::ErrorHandler::DEFAULT_FILTERED_ERROR_CLASSES
  end

  # The server answering with an error is not a blip: MISCONF, OOM, READONLY,
  # NOPERM and WRONGPASS heal only when someone acts, and every write fails until then.
  def test_reports_redis_command_errors_rate_limited_per_code
    %w[MISCONF OOM READONLY NOPERM WRONGPASS].each do |code|
      2.times { h_shared.call(RedisClient::CommandError.parse("#{code} nope"), { context: 'Error fetching job' }) }
    end

    assert_equal 5, FakeSentry.captured.size, 'each code once per window'
  end

  def test_rate_limited_report_says_how_many_it_swallowed
    now = 0
    h = handler(coalescer: Wurk::ErrorCoalescer.new(window: 60, clock: -> { now }))
    3.times { h.call(RedisClient::CommandError.parse('MISCONF no'), {}) }
    now = 60
    h.call(RedisClient::CommandError.parse('MISCONF no'), {})

    assert_equal 2, FakeSentry.captured.last[:options][:extra][:suppressed]
  end

  def test_never_reports_the_retry_machinerys_control_flow
    h_shared.call(Wurk::JobRetry::Skip.new, {})
    h_shared.call(Wurk::JobRetry::Handled.new, {})

    assert_empty FakeSentry.captured
  end

  def test_report_after_attempts_reports_that_attempt_of_a_job_failure
    h = handler(report_after_attempts: 2)
    context = { context: 'Job raised exception', job: { 'class' => 'J', 'retry' => 25 } }
    h.call(Boom.new, context)

    assert_empty FakeSentry.captured, 'attempt 1'
    h.call(Boom.new, context.merge(job: { 'class' => 'J', 'retry' => 25, 'retry_count' => 0 }))

    assert_equal 1, FakeSentry.captured.size, 'attempt 2'
    h.call(Boom.new, context.merge(job: { 'class' => 'J', 'retry' => 25, 'retry_count' => 1 }))

    assert_equal 1, FakeSentry.captured.size, 'attempt 3 is neither the asked attempt nor terminal'
  end

  # The default lets through what the server answered with. A list the host wrote
  # means what it says, by ancestry, the contract `filtered_error_classes:` has.
  def test_an_explicit_list_filters_read_only_and_master_down_by_ancestry
    explicit = handler(filtered_error_classes: [RedisClient::ConnectionError])
    explicit.call(RedisClient::ReadOnlyError.new('READONLY no'), {})
    explicit.call(RedisClient::MasterDownError.new('MASTERDOWN no'), {})

    assert_empty FakeSentry.captured
    h_shared.call(RedisClient::ReadOnlyError.new('READONLY no'), {})

    assert_equal 1, FakeSentry.captured.size, 'the default still reports it'
  end

  def test_exposes_its_filter_list
    assert_equal [Boom], handler(filtered_error_classes: [Boom]).filtered_error_classes
  end

  # =====================================================================
  # Job failures ("Job raised exception") — Middleware's unless it never saw them
  # =====================================================================

  def job_failure(job) = { context: 'Job raised exception', job: job }

  def terminal_job = { 'class' => 'MyJob', 'jid' => 'j1', 'queue' => 'critical', 'retry' => false, 'args' => [] }

  def test_skips_a_job_failure_the_middleware_already_saw
    error = Boom.new
    Wurk::Sentry::ErrorHandler.seen_by_middleware!(error)
    handler.call(error, job_failure(terminal_job))

    assert_empty FakeSentry.captured
  end

  def test_the_middleware_claim_is_consumed
    error = Boom.new
    Wurk::Sentry::ErrorHandler.seen_by_middleware!(error)
    handler.call(error, job_failure(terminal_job))

    assert_nil Thread.current[Wurk::Sentry::ErrorHandler::SEEN_BY_MIDDLEWARE]
  end

  def test_captures_a_terminal_job_failure_the_middleware_never_saw
    Wurk::Sentry::ErrorHandler.seen_by_middleware!(Boom.new('another job'))
    error = Boom.new('class failed to load')
    handler.call(error, job_failure(terminal_job))

    assert_equal [error], FakeSentry.captured_exceptions
    assert_equal 'Wurk/MyJob', FakeSentry.last_scope.transaction_name
  ensure
    Thread.current[Wurk::Sentry::ErrorHandler::SEEN_BY_MIDDLEWARE] = nil
  end

  def test_skips_an_unseen_job_failure_that_will_be_retried
    handler.call(Boom.new, job_failure(terminal_job.merge('retry' => true)))

    assert_empty FakeSentry.captured
  end

  def test_the_transport_filter_does_not_hide_a_dead_job
    handler.call(redis_error, job_failure(terminal_job))

    assert_equal 1, FakeSentry.captured.size
  end

  def test_a_job_failure_without_a_job_hash_is_reported_as_is
    handler.call(Boom.new, { context: 'Job raised exception' })

    assert_equal 1, FakeSentry.captured.size
  end

  # End to end through a real Processor: the middleware captures the terminal
  # attempt inside the job's scope, and the processor's error_handlers dispatch
  # of the same failure must not add a second event.
  def test_a_failed_job_is_reported_exactly_once_through_the_processor
    config = Wurk::Configuration.new
    config.logger = Logger.new(IO::NULL)
    Wurk::Sentry.install!(config)
    queue = "seh-#{Process.pid}-#{SecureRandom.hex(4)}"
    capsule = Wurk::Capsule.new('sentry', config)
    capsule.queues = [queue]
    capsule.fetcher = Wurk::Fetcher::Reliable.new(capsule)
    klass = Class.new do
      include Wurk::Worker

      def perform = raise(SentryErrorHandlerTest::Boom, 'terminal')
    end
    Object.const_set("SEH_Worker_#{Process.pid}_#{SecureRandom.hex(4)}", klass)
    payload = { 'class' => klass.name, 'args' => [], 'queue' => queue, 'jid' => SecureRandom.hex(12), 'retry' => false }
    capsule.redis_pool.with { |c| c.call('LPUSH', "queue:#{queue}", Wurk.dump_json(payload)) }

    Wurk::Processor.new(capsule).process_one
    capsule.fetcher.flush_pending_acks

    assert_equal 1, FakeSentry.captured.size
    assert_equal 'terminal', FakeSentry.captured_exceptions.first.message
  ensure
    capsule&.redis_pool&.with { |c| c.call('DEL', "queue:#{queue}") }
  end

  # =====================================================================
  # Never reported
  # =====================================================================

  def test_does_not_report_wurk_shutdown
    handler.call(Wurk::Shutdown.new, { context: '!shutdown' })

    assert_empty FakeSentry.captured
  end

  # =====================================================================
  # Inert without Sentry
  # =====================================================================

  def test_no_op_when_sentry_is_not_initialized
    FakeSentry.initialized = false

    assert_nil handler.call(Boom.new, {})
  end

  def test_captures_nothing_when_sentry_is_not_initialized
    FakeSentry.initialized = false
    handler.call(Boom.new, {})

    assert_empty FakeSentry.captured
  end

  def test_no_op_when_sentry_ruby_is_absent
    Object.send(:remove_const, :Sentry)

    assert_nil handler.call(Boom.new, {})
  end

  # =====================================================================
  # Wired through Configuration#handle_exception
  # =====================================================================

  def test_reports_through_the_real_handle_exception_path
    config = Wurk::Configuration.new
    config.logger = Logger.new(IO::NULL)
    Wurk::Sentry.install!(config)

    config.handle_exception(Boom.new('fetch failed'), { context: 'Error fetching job' })

    assert_equal 1, FakeSentry.captured.size
  end

  def test_the_default_logging_handler_still_runs
    out = StringIO.new
    config = Wurk::Configuration.new
    config.logger = Logger.new(out)
    Wurk::Sentry.install!(config)

    config.handle_exception(Boom.new('fetch failed'), { context: 'Error fetching job' })

    assert_includes out.string, 'fetch failed'
  end
end
