# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/fake_sentry'
require 'wurk/sentry'

# Wurk::Sentry::ErrorHandler — the half of the integration that sees the
# failures which are *not* job failures: the fetch loop, the shutdown path,
# unparseable payloads, and the retry machinery's own meta-errors.
class SentryErrorHandlerTest < Wurk::Test::UnitCase
  include SentryConstantSwap

  parallelize_me!

  class Boom < StandardError; end

  def handler(**) = Wurk::Sentry::ErrorHandler.new(**)

  def redis_error
    # RedisClient::Error subclasses carry the same self-healing semantics as
    # the base class; the filter must walk the ancestry, not match exactly.
    RedisClient::ConnectionError.new('Connection reset by peer')
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

  def test_default_filter_list_is_the_configurations_redis_error_classes
    assert_equal Wurk::Configuration::REDIS_ERROR_CLASSES,
                 Wurk::Sentry::ErrorHandler::DEFAULT_FILTERED_ERROR_CLASSES
  end

  def test_exposes_its_filter_list
    assert_equal [Boom], handler(filtered_error_classes: [Boom]).filtered_error_classes
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
