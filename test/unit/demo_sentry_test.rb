# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../demo/lib/demo_sentry_policy'
require 'wurk/sentry'

# DemoSentryPolicy — the demo's error-reporting gate, its three drop rules and
# its scrubbing — plus the initializer that turns them on.
#
# Demo-level: no Rails boot, no Redis, no sentry-ruby. The SDK is stood in for
# by a fake ::Sentry installed for the duration of each test: requiring
# sentry-ruby at file scope would define ::Sentry for every worker in the
# suite (minitest-parallel_fork loads every test file in the parent), and the
# suites that assert the SDK's absence would break.
class DemoSentryTest < Wurk::Test::UnitCase
  parallelize_me!

  POLICY_PATH = File.expand_path('../../demo/lib/demo_sentry_policy.rb', __dir__)
  INITIALIZER_PATH = File.expand_path('../../demo/config/initializers/sentry.rb', __dir__)
  APPLICATION_PATH = File.expand_path('../../demo/config/application.rb', __dir__)
  DSN = 'https://public@example.invalid/1'

  # The gem's own job-context key. The doubles use it instead of a literal, so
  # a rename in the gem cannot leave them matching while the policy stops.
  JOB_CONTEXT_KEY = Wurk::Sentry::JobContext::CONTEXT_KEY

  # The parts of a Sentry event the policy reads. Structs, because the policy
  # only ever calls plain readers on them.
  FakeRequest = Struct.new(:headers, :cookies)
  FakeEvent = Struct.new(:request, :extra, :contexts, :tags)

  # An event whose reader blows up: a partial event must be dropped, not
  # raised into Sentry's capture path.
  class ExplodingEvent
    def contexts
      raise 'the event reader exploded'
    end
  end

  # A request object that only reads: the policy can see the credentials but
  # has nowhere to put the scrubbed copy, so the event must be dropped rather
  # than sent with them (fail closed).
  class ReadOnlyRequest
    attr_reader :headers, :cookies

    def initialize(headers, cookies)
      @headers = headers
      @cookies = cookies
    end
  end

  # A stand-in for the sentry-ruby SDK: it records what the initializer asked
  # it to do, so a test can assert the SDK was never initialized.
  module FakeSdk
    class Config
      attr_accessor :dsn, :background_worker_threads, :send_default_pii, :before_send
    end

    class << self
      attr_reader :init_calls, :config

      def reset!
        @init_calls = 0
        @config = nil
        @initialized = false
      end

      def init
        @init_calls += 1
        @config = Config.new
        yield @config if block_given?
        @initialized = true
        @config
      end

      def initialized?
        @initialized
      end
    end
  end

  def setup
    super
    FakeSdk.reset!
    @previous_sentry = Object.const_get(:Sentry) if Object.const_defined?(:Sentry)
    Object.send(:remove_const, :Sentry) if Object.const_defined?(:Sentry)
    Object.const_set(:Sentry, FakeSdk)
    @saved_env = ENV.to_h.slice('WURK_DEMO_REPORT_ERRORS', 'SENTRY_DSN')
    ENV.delete('WURK_DEMO_REPORT_ERRORS')
    ENV.delete('SENTRY_DSN')
  end

  def teardown
    ENV.delete('WURK_DEMO_REPORT_ERRORS')
    ENV.delete('SENTRY_DSN')
    @saved_env.each { |key, value| ENV[key] = value }
    Object.send(:remove_const, :Sentry) if Object.const_defined?(:Sentry)
    Object.const_set(:Sentry, @previous_sentry) if @previous_sentry
    Wurk.configuration.server_middleware.remove(Wurk::Sentry::Middleware)
    Wurk.configuration.error_handlers.reject! { |handler| handler.is_a?(Wurk::Sentry::ErrorHandler) }
    super
  end

  def event_for(job_class, headers: {}, cookies: {}, extra: {}, contexts: nil, tags: {})
    job_context = {
      'class' => job_class,
      'jid' => 'abc123',
      'queue' => 'default'
    }

    FakeEvent.new(
      FakeRequest.new(headers, cookies),
      extra,
      contexts || { JOB_CONTEXT_KEY => job_context },
      tags
    )
  end

  def with_env(vars)
    ENV.delete('WURK_DEMO_REPORT_ERRORS')
    ENV.delete('SENTRY_DSN')
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    ENV.delete('WURK_DEMO_REPORT_ERRORS')
    ENV.delete('SENTRY_DSN')
  end

  def middleware_klasses
    Wurk.configuration.server_middleware.entries.map(&:klass)
  end

  def handler_classes
    Wurk.configuration.error_handlers.map(&:class)
  end

  # =====================================================================
  # The gate: the flag AND a DSN
  # =====================================================================

  def test_the_gate_needs_the_flag_and_a_dsn
    assert DemoSentryPolicy.enabled?({ 'WURK_DEMO_REPORT_ERRORS' => '1', 'SENTRY_DSN' => DSN })
    refute DemoSentryPolicy.enabled?({ 'WURK_DEMO_REPORT_ERRORS' => '1' })
    refute DemoSentryPolicy.enabled?({ 'SENTRY_DSN' => DSN })
    refute DemoSentryPolicy.enabled?({})
  end

  def test_the_gate_refuses_a_blank_dsn
    refute DemoSentryPolicy.enabled?({ 'WURK_DEMO_REPORT_ERRORS' => '1', 'SENTRY_DSN' => '' })
    refute DemoSentryPolicy.enabled?({ 'WURK_DEMO_REPORT_ERRORS' => '1', 'SENTRY_DSN' => '   ' })
  end

  def test_the_gate_reads_the_environment_by_default
    with_env('WURK_DEMO_REPORT_ERRORS' => '1', 'SENTRY_DSN' => DSN) do
      assert_predicate DemoSentryPolicy, :enabled?
    end
  end

  def test_the_gate_reads_a_symbol_keyed_env_hash
    assert DemoSentryPolicy.enabled?({ WURK_DEMO_REPORT_ERRORS: '1', SENTRY_DSN: DSN })
    refute DemoSentryPolicy.enabled?({ WURK_DEMO_REPORT_ERRORS: '1' })
    refute DemoSentryPolicy.enabled?({ SENTRY_DSN: DSN })
  end

  def test_the_dsn_is_the_environment_variable
    assert_equal DSN, DemoSentryPolicy.dsn({ 'SENTRY_DSN' => DSN })
    assert_nil DemoSentryPolicy.dsn({})
  end

  # =====================================================================
  # Drop rule 1: the demo's intentional failures
  # =====================================================================

  def test_the_job_context_key_comes_from_the_gem
    assert_equal Wurk::Sentry::JobContext::CONTEXT_KEY, DemoSentryPolicy::JOB_CONTEXT_KEY

    policy = File.read(POLICY_PATH)

    assert_includes policy, 'Wurk::Sentry::JobContext::CONTEXT_KEY'
    refute_includes policy, 'JOB_CONTEXT_KEY = :wurk'
  end

  def test_drops_a_broken_job_event
    assert_nil DemoSentryPolicy.before_send(event_for('BrokenJob'))
  end

  def test_drops_a_flaky_webhook_event
    assert_nil DemoSentryPolicy.before_send(event_for('FlakyWebhookJob'))
  end

  # =====================================================================
  # Drop rule 2: a soak-tagged event
  # =====================================================================

  def test_drops_a_soak_tagged_event
    assert_nil DemoSentryPolicy.before_send(event_for('SendReceiptJob', tags: { 'soak' => 'true' }))
  end

  def test_drops_a_soak_marked_by_value
    assert_nil DemoSentryPolicy.before_send(event_for('SendReceiptJob', tags: { 'run' => 'SOAK' }))
  end

  # =====================================================================
  # Drop rule 3: nothing else is dropped
  # =====================================================================

  def test_keeps_an_ordinary_event
    event = event_for('SendReceiptJob')

    assert_same event, DemoSentryPolicy.before_send(event)
  end

  def test_keeps_an_event_with_an_unrelated_tag
    event = event_for('SendReceiptJob', tags: { 'queue' => 'default' })

    assert_same event, DemoSentryPolicy.before_send(event)
  end

  def test_keeps_an_event_from_a_job_that_fails_on_purpose_only_by_chance
    # ExportChunkJob fails 8% of the time by design: it is the demo's batch
    # failure, not an intentional failure, so its events are reported.
    event = event_for('ExportChunkJob')

    assert_same event, DemoSentryPolicy.before_send(event)
  end

  # =====================================================================
  # Scrubbing: request headers
  # =====================================================================

  def test_removes_credential_headers
    event = event_for(
      'SendReceiptJob',
      headers: {
        'Authorization' => 'Bearer abcdef',
        'Cookie' => 'session=abc',
        'X-Api-Key' => 'k',
        'Accept' => 'application/json'
      }
    )

    scrubbed = DemoSentryPolicy.before_send(event)

    assert_equal({ 'Accept' => 'application/json' }, scrubbed.request.headers)
  end

  def test_removes_a_header_whose_value_looks_like_a_credential
    event = event_for('SendReceiptJob', headers: { 'X-Trace' => 'sk-abcdefghijklmnop' })

    scrubbed = DemoSentryPolicy.before_send(event)

    assert_empty scrubbed.request.headers
  end

  def test_removes_a_session_cookie_and_keeps_the_theme_cookie
    event = event_for('SendReceiptJob', cookies: { 'session' => 'abc123', 'theme' => 'dark' })

    scrubbed = DemoSentryPolicy.before_send(event)

    assert_equal({ 'theme' => 'dark' }, scrubbed.request.cookies)
  end

  # =====================================================================
  # Scrubbing: a hash-shaped request
  #
  # An event reconstructed from JSON carries its request as a plain hash,
  # not the SDK's request object — its credentials must be scrubbed all the
  # same, even though `field` reads only methods.
  # =====================================================================

  def test_scrubs_a_hash_shaped_request
    event = event_for('SendReceiptJob')
    event.request = {
      'headers' => { 'Authorization' => 'Bearer abcdef', 'Accept' => 'application/json' },
      'cookies' => { 'session' => 'abc123', 'theme' => 'dark' }
    }

    scrubbed = DemoSentryPolicy.before_send(event)

    assert_equal({ 'Accept' => 'application/json' }, scrubbed.request['headers'])
    assert_equal({ 'theme' => 'dark' }, scrubbed.request['cookies'])
  end

  def test_scrubs_a_hash_shaped_request_keyed_by_symbols
    event = event_for('SendReceiptJob')
    event.request = { headers: { 'X-Api-Key' => 'k', 'Accept' => 'text/html' } }

    scrubbed = DemoSentryPolicy.before_send(event)

    assert_equal({ 'Accept' => 'text/html' }, scrubbed.request[:headers])
  end

  def test_keeps_a_hash_shaped_request_with_nothing_to_scrub
    event = event_for('SendReceiptJob')
    event.request = { 'headers' => { 'Accept' => 'application/json' }, 'cookies' => { 'theme' => 'dark' } }

    assert_same event, DemoSentryPolicy.before_send(event)
    assert_equal({ 'Accept' => 'application/json' }, event.request['headers'])
  end

  def test_drops_an_event_whose_read_only_request_holds_credentials
    event = event_for('SendReceiptJob')
    event.request = ReadOnlyRequest.new({ 'Authorization' => 'Bearer abcdef' }, {})

    assert_nil DemoSentryPolicy.before_send(event)
  end

  def test_keeps_an_event_whose_read_only_request_holds_nothing_sensitive
    event = event_for('SendReceiptJob')
    event.request = ReadOnlyRequest.new({ 'Accept' => 'application/json' }, {})

    assert_same event, DemoSentryPolicy.before_send(event)
  end

  # =====================================================================
  # Scrubbing: a request field that is not a Hash
  #
  # A raw request env arrives as a serialized cookie String where the SDK
  # would put a Hash — no entries, so a per-entry scrub has nothing to work
  # on. Nothing inside such a field can be vouched for, so a populated one
  # fails closed: the event is dropped rather than sent with its session
  # value intact.
  # =====================================================================

  def test_drops_an_event_whose_cookies_are_a_serialized_string
    event = event_for('SendReceiptJob', cookies: 'session=abc123; theme=dark')

    assert_nil DemoSentryPolicy.before_send(event)
  end

  def test_drops_an_event_whose_serialized_cookie_jar_has_nothing_sensitive
    event = event_for('SendReceiptJob', cookies: 'theme=dark')

    assert_nil DemoSentryPolicy.before_send(event)
  end

  def test_drops_an_event_whose_hash_request_holds_serialized_cookies
    event = event_for('SendReceiptJob')
    event.request = { 'headers' => { 'Accept' => 'application/json' }, 'cookies' => 'session=abc123' }

    assert_nil DemoSentryPolicy.before_send(event)
  end

  def test_drops_an_event_whose_headers_are_a_serialized_string
    event = event_for('SendReceiptJob', headers: 'Cookie: session=abc123')

    assert_nil DemoSentryPolicy.before_send(event)
  end

  def test_keeps_an_event_with_an_empty_serialized_cookie_jar
    event = event_for('SendReceiptJob', cookies: '')

    assert_same event, DemoSentryPolicy.before_send(event)
  end

  # =====================================================================
  # Scrubbing: job arguments
  # =====================================================================

  def test_removes_credential_shaped_job_arguments
    event = event_for(
      'SendReceiptJob',
      extra: {
        job: {
          'args' => ['[REDACTED:openai_key]', '[REDACTED:email]', 'user@example.com', 42, { 'api_key' => 'x' }]
        }
      }
    )

    scrubbed = DemoSentryPolicy.before_send(event)
    args = scrubbed.extra[:job]['args']

    refute_includes args, '[REDACTED:openai_key]'
    refute_includes args, '[REDACTED:email]'
    refute_includes args, 'user@example.com'
    assert_includes args, 42
    assert_empty(args.select { |arg| arg.is_a?(Hash) && arg.key?('api_key') })
  end

  def test_keeps_ordinary_job_arguments
    event = event_for('SendReceiptJob', extra: { job: { 'args' => [42, 'chunk-3', { 'size' => 10 }] } })

    scrubbed = DemoSentryPolicy.before_send(event)

    assert_equal [42, 'chunk-3', { 'size' => 10 }], scrubbed.extra[:job]['args']
  end

  def test_removes_credential_shaped_arguments_inside_a_nested_array
    event = event_for('SendReceiptJob', extra: { job: { 'args' => [%w[sk-abcdefghijklmnop ok], 42] } })

    scrubbed = DemoSentryPolicy.before_send(event)

    assert_equal [['ok'], 42], scrubbed.extra[:job]['args']
  end

  def test_removes_credential_shaped_arguments_in_the_job_context
    job_context = {
      'class' => 'SendReceiptJob',
      'args' => ['sk-abcdefghijklmnop', 7]
    }
    event = event_for(
      'SendReceiptJob',
      contexts: { JOB_CONTEXT_KEY => job_context }
    )

    scrubbed = DemoSentryPolicy.before_send(event)

    assert_equal [7], scrubbed.contexts[JOB_CONTEXT_KEY]['args']
  end

  def test_removes_credential_shaped_arguments_in_extra
    event = event_for('SendReceiptJob', extra: { args: ['user@example.com', 'ok'] })

    scrubbed = DemoSentryPolicy.before_send(event)

    assert_equal ['ok'], scrubbed.extra[:args]
  end

  # =====================================================================
  # A malformed event never takes the reporting down
  # =====================================================================

  def test_never_raises_on_a_malformed_event
    assert_silent { DemoSentryPolicy.before_send(nil) }
    assert_silent { DemoSentryPolicy.before_send(Object.new) }
    assert_silent { DemoSentryPolicy.before_send('not an event') }
  end

  def test_drops_an_event_whose_reader_raises
    assert_nil DemoSentryPolicy.before_send(ExplodingEvent.new)
  end

  def test_an_event_without_any_field_survives_untouched
    event = FakeEvent.new(nil, nil, nil, nil)

    assert_same event, DemoSentryPolicy.before_send(event)
  end

  # =====================================================================
  # The initializer: off unless the gate is on
  # =====================================================================

  def test_the_initializer_does_nothing_without_the_flag
    middleware = middleware_klasses
    handlers = handler_classes

    with_env('SENTRY_DSN' => DSN) { load INITIALIZER_PATH }

    assert_equal 0, FakeSdk.init_calls
    refute_predicate FakeSdk, :initialized?
    assert_equal middleware, middleware_klasses
    assert_equal handlers, handler_classes
  end

  def test_the_initializer_does_nothing_without_a_dsn
    middleware = middleware_klasses
    handlers = handler_classes

    with_env('WURK_DEMO_REPORT_ERRORS' => '1') { load INITIALIZER_PATH }

    assert_equal 0, FakeSdk.init_calls
    refute_predicate FakeSdk, :initialized?
    assert_equal middleware, middleware_klasses
    assert_equal handlers, handler_classes
  end

  def test_the_initializer_does_nothing_without_the_flag_or_a_dsn
    middleware = middleware_klasses
    handlers = handler_classes

    with_env({}) { load INITIALIZER_PATH }

    assert_equal 0, FakeSdk.init_calls
    refute_predicate FakeSdk, :initialized?
    assert_equal middleware, middleware_klasses
    assert_equal handlers, handler_classes
  end

  def test_the_enabled_initializer_installs_the_sentry_integration
    with_env('WURK_DEMO_REPORT_ERRORS' => '1', 'SENTRY_DSN' => DSN) { load INITIALIZER_PATH }

    assert_equal 1, FakeSdk.init_calls
    assert_predicate FakeSdk, :initialized?
    assert_equal DSN, FakeSdk.config.dsn
    assert_equal 0, FakeSdk.config.background_worker_threads
    refute FakeSdk.config.send_default_pii
    assert_respond_to FakeSdk.config.before_send, :call
    assert Wurk.configuration.server_middleware.exists?(Wurk::Sentry::Middleware)
    assert_equal 1, Wurk.configuration.error_handlers.grep(Wurk::Sentry::ErrorHandler).size
  end

  def test_the_installed_before_send_drops_an_intentional_failure
    with_env('WURK_DEMO_REPORT_ERRORS' => '1', 'SENTRY_DSN' => DSN) { load INITIALIZER_PATH }

    assert_nil FakeSdk.config.before_send.call(event_for('BrokenJob'), nil)
  end

  # =====================================================================
  # One definition of the gate
  # =====================================================================

  def test_the_gate_is_defined_in_one_place
    policy = File.read(POLICY_PATH)
    application = File.read(APPLICATION_PATH)
    initializer = File.read(INITIALIZER_PATH)

    assert_includes policy, 'WURK_DEMO_REPORT_ERRORS'
    assert_includes policy, 'SENTRY_DSN'
    refute_includes application, 'ENV["WURK_DEMO_REPORT_ERRORS"]'
    refute_includes initializer, 'ENV["WURK_DEMO_REPORT_ERRORS"]'
    assert_includes application, 'DemoSentryPolicy.enabled?'
    assert_includes initializer, 'DemoSentryPolicy.enabled?'
  end
end
