# frozen_string_literal: true

require_relative '../../test/test_helper'
require_relative '../app/jobs/demo_canary_job'
require_relative '../lib/demo_sentry_policy'

class DemoCanaryTest < Minitest::Test
  ENV_KEYS = %w[WURK_DEMO_CANARY WURK_DEMO_REPORT_ERRORS SENTRY_DSN].freeze
  INITIALIZER = File.expand_path('../config/initializers/sentry.rb', __dir__)
  HANDSHAKE = Wurk::Sentry::ErrorHandler::SEEN_BY_MIDDLEWARE
  Event = Struct.new(:request, :extra, :contexts, :tags)

  class Scope
    attr_reader :tags, :contexts

    def initialize
      @tags = { 'existing' => 'kept' }
      @contexts = {}
    end

    def clear_breadcrumbs; end
    def set_transaction_name(*, **); end
    def set_tags(tags) = @tags.merge!(tags)
    def set_context(key, value) = @contexts[key] = value
  end

  module Sdk
    Config = Struct.new(:dsn, :background_worker_threads, :send_default_pii, :before_send)

    class << self
      attr_reader :config, :captured, :exceptions

      def reset!
        @config = nil
        @captured = []
        @exceptions = []
        @scope = nil
      end

      def init
        @config = Config.new
        yield @config
      end

      def initialized? = !@config.nil?
      def clone_hub_to_current_thread; end

      def with_scope
        previous = @scope
        @scope = Scope.new
        yield @scope
      ensure
        @scope = previous
      end

      def capture_exception(exception)
        @exceptions << exception
        event = Event.new({}, {}, @scope.contexts.dup, @scope.tags.dup)
        filtered = @config.before_send.call(event, {})
        @captured << filtered if filtered
      end
    end
  end

  def setup
    @env = ENV.to_h.slice(*ENV_KEYS)
    ENV_KEYS.each { |key| ENV.delete(key) }
    @previous_sentry = Object.const_get(:Sentry) if Object.const_defined?(:Sentry)
    Object.send(:remove_const, :Sentry) if Object.const_defined?(:Sentry)
    @configuration = Wurk.configuration
    Wurk.instance_variable_set(:@configuration, Wurk::Configuration.new)
    @handshake = Thread.current[HANDSHAKE]
    Thread.current[HANDSHAKE] = nil
    Sdk.reset!
  end

  def teardown
    ENV_KEYS.each { |key| ENV.delete(key) }
    @env.each { |key, value| ENV[key] = value }
    Object.send(:remove_const, :Sentry) if Object.const_defined?(:Sentry)
    Object.const_set(:Sentry, @previous_sentry) if @previous_sentry
    Wurk.instance_variable_set(:@configuration, @configuration)
    Thread.current[HANDSHAKE] = @handshake
    Sdk.reset!
  end

  def install_reporting
    Object.const_set(:Sentry, Sdk)
    ENV['WURK_DEMO_REPORT_ERRORS'] = '1'
    ENV['SENTRY_DSN'] = 'https://public@example.invalid/1'
    load INITIALIZER
  end

  def event_for(klass = 'DemoCanaryJob', tags: {})
    Event.new({}, {}, { DemoSentryPolicy::JOB_CONTEXT_KEY => { 'class' => klass } }, tags)
  end

  def test_only_exactly_one_arms_the_sdk_independent_job
    refute Object.const_defined?(:Sentry)
    [nil, '', '0', 'false', 'true', '2', '01', ' 1', '1 '].each do |flag|
      ENV['WURK_DEMO_CANARY'] = flag
      assert_nil DemoCanaryJob.new.perform, "flag #{flag.inspect} must be dormant"
    end
    ENV['WURK_DEMO_CANARY'] = '1'
    error = assert_raises(DemoCanaryJob::CanaryFault) { DemoCanaryJob.new.perform }
    assert_match(/DEMO-ONLY CANARY/, error.message)
    assert_equal 0, DemoCanaryJob.get_sidekiq_options['retry']
    refute Object.const_defined?(:Sentry)
  end

  def test_terminal_failure_is_captured_and_tagged_through_installed_policy
    install_reporting
    ENV['WURK_DEMO_CANARY'] = '1'
    payload = { 'class' => 'DemoCanaryJob', 'jid' => 'canary123', 'queue' => 'default' }
    error = assert_raises(DemoCanaryJob::CanaryFault) do
      Wurk.configuration.server_middleware.invoke(DemoCanaryJob.new, payload, 'default') do
        DemoCanaryJob.new.perform
      end
    end

    assert_equal [error], Sdk.exceptions
    assert_equal 1, Sdk.captured.size
    event = Sdk.captured.first
    assert_equal 'demo_fault', event.tags['canary']
    assert_equal 'kept', event.tags['existing']
    assert_equal 'default', event.tags[:queue]
    assert_equal 'canary123', event.tags[:jid]
    refute DemoSentryPolicy.intentional_failure?(event)
    refute DemoSentryPolicy.soak?(event)
    Wurk.configuration.error_handlers.grep(Wurk::Sentry::ErrorHandler).each do |handler|
      handler.call(error, { context: 'Job raised exception', job: payload }, Wurk.configuration)
    end
    assert_equal [error], Sdk.exceptions
    assert_nil Thread.current[HANDSHAKE]
  end

  def test_armed_job_does_not_enable_reporting
    Object.const_set(:Sentry, Sdk)
    ENV['WURK_DEMO_CANARY'] = '1'
    [{}, { 'WURK_DEMO_REPORT_ERRORS' => '1' }, { 'SENTRY_DSN' => 'https://public@example.invalid/1' }].each do |env|
      %w[WURK_DEMO_REPORT_ERRORS SENTRY_DSN].each { |key| ENV.delete(key) }
      env.each { |key, value| ENV[key] = value }
      load INITIALIZER
      refute DemoSentryPolicy.enabled?
      refute Sdk.initialized?
      middleware = Wurk::Sentry::Middleware.new
      assert_raises(DemoCanaryJob::CanaryFault) do
        middleware.call(DemoCanaryJob.new, { 'class' => 'DemoCanaryJob' }, 'default') do
          DemoCanaryJob.new.perform
        end
      end
      assert_empty Sdk.exceptions
    end
  end

  def test_tagging_preserves_scrubbing_and_never_bypasses_drops
    install_reporting
    event = event_for(tags: { 'existing' => 'kept' })
    event.request = { headers: { 'Authorization' => 'Bearer example', 'Accept' => 'text/plain' },
                      cookies: { 'session' => 'example', 'theme' => 'dark' } }
    event.extra = { args: ['person@example.invalid', { 'password' => 'example', 'count' => 2 }, 'safe'] }
    event.contexts[DemoSentryPolicy::JOB_CONTEXT_KEY]['args'] = ['person@example.invalid', 'safe']
    assert_same event, Sdk.config.before_send.call(event)
    assert_equal({ 'existing' => 'kept', 'canary' => 'demo_fault' }, event.tags)
    assert_equal({ 'Accept' => 'text/plain' }, event.request[:headers])
    assert_equal({ 'theme' => 'dark' }, event.request[:cookies])
    assert_equal [{ 'count' => 2 }, 'safe'], event.extra[:args]
    assert_equal ['safe'], event.contexts[DemoSentryPolicy::JOB_CONTEXT_KEY]['args']

    %w[BrokenJob FlakyWebhookJob].each do |klass|
      assert_nil Sdk.config.before_send.call(event_for(klass))
    end
    [{ 'soak' => 'true' }, { 'run' => 'SOAK' }].each do |tags|
      soaked = event_for(tags: tags)
      assert_nil Sdk.config.before_send.call(soaked)
      refute soaked.tags.key?('canary')
    end
    unsafe = event_for
    unsafe.request = { cookies: 'session=example' }
    assert_nil Sdk.config.before_send.call(unsafe)
    ordinary = event_for('WelcomeJob', tags: { 'existing' => 'kept' })
    assert_same ordinary, Sdk.config.before_send.call(ordinary)
    assert_equal({ 'existing' => 'kept' }, ordinary.tags)
  end

  def test_canary_tag_handles_missing_tags_and_string_context_keys
    event = Event.new(nil, nil, { 'wurk' => { 'class' => 'DemoCanaryJob' } }, nil)
    assert_same event, DemoSentryPolicy.before_send(event)
    assert_equal({ 'canary' => 'demo_fault' }, event.tags)
  end
end
