# frozen_string_literal: true

require_relative '../test_helper'
# The CurrentAttributes cases need `ActiveSupport::CurrentAttributes`. The
# three files below are what it loads in ActiveSupport 8.1 — and deliberately
# not `active_support` itself: that one pulls in the i18n gem, and a defined
# ::I18n makes the I18n middleware write a "locale" key into the payload of
# every job this worker pushes.
require 'active_support/code_generator'
require 'active_support/current_attributes'
require 'active_support/isolated_execution_state'
require 'json'
require 'securerandom'
require 'sidekiq/middleware/current_attributes'

# Parity oracle for the built-in middleware, written from the documented
# promise in docs/target/sidekiq-free.md §10.3 ("Built-in middleware
# (auto-registered when required)"), not from Wurk's middleware code.
#
# §10.3 names four things: `Sidekiq::Job::InterruptHandler` is registered when
# `sidekiq/cli` is required and re-pushes an interrupted job before raising
# `JobRetry::Skip`; `Sidekiq::Metrics::Middleware` is registered for the CLI
# and for embedded runs and tracks per-class p/f/ms; `Sidekiq::Middleware::I18n`
# is registered when `sidekiq/middleware/i18n` is required and carries
# `I18n.locale` across a job; and `Sidekiq::CurrentAttributes.persist` adds
# Save to the client chain and Load to both, with payload keys "cattr",
# "cattr_1", "cattr_2", ...
#
# The registration cases run in a cold process, so they assert what the
# documented require registers rather than what this worker already loaded.
# The behaviour cases run against real Redis through a real `Sidekiq::Processor`
# over a capsule, and read what the execution itself observed.
class BuiltinParityTest < Wurk::Test::UnitCase
  parallelize_me!

  # What the probes saw. One array per test, cleared in setup.
  module Probe
    MUTEX = Mutex.new
    @seen = []

    class << self
      def record(entry) = MUTEX.synchronize { @seen << entry }
      def entries = MUTEX.synchronize { @seen.dup }
      def clear = MUTEX.synchronize { @seen.clear }
    end
  end

  # The attributes the CurrentAttributes cases persist.
  class ProbeAttributes < ActiveSupport::CurrentAttributes
    attribute :probe_value
  end

  class SecondAttributes < ActiveSupport::CurrentAttributes
    attribute :second_value
  end

  # A stand-in for the i18n gem: the middleware reads and writes `I18n.locale`
  # and nothing else. The real constant is left alone for the rest of the
  # worker — a defined ::I18n would put a "locale" key in the payload of every
  # job the I18n client middleware sees.
  module FakeI18n
    class << self
      attr_accessor :locale
    end
  end

  # The job the probes run: it reports what it saw, so the assertions read
  # the execution's own observation rather than the middleware's intent.
  class ProbeJob
    include Sidekiq::Job

    def perform(token)
      Probe.record(
        token: token,
        locale: (::I18n.locale.to_s if defined?(::I18n)),
        first: ProbeAttributes.attributes.to_h.transform_keys(&:to_s),
        second: SecondAttributes.attributes.to_h.transform_keys(&:to_s)
      )
    end
  end

  def setup
    super
    @token = SecureRandom.hex(6)
    @queue = "bi-#{@token}"
    @config = Sidekiq::Config.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: Wurk::Test.redis_url }
    Probe.clear
  end

  def teardown
    @capsule&.fetcher&.flush_pending_acks
    @config&.reset_redis_pools!
    unregister_current_attributes
    super
  end

  # --- §10.3 Sidekiq::Job::InterruptHandler ---------------------------------

  def test_interrupt_registration
    assert_subprocess(<<~RUBY)
      require "sidekiq/cli"
      chain = Sidekiq.default_configuration.server_middleware
      exit(chain.exists?(Sidekiq::Job::InterruptHandler) ? 0 : 1)
    RUBY
  end

  def test_interrupt_repush
    handler = Sidekiq::Job::InterruptHandler.new
    handler.config = @config

    assert_raises(Sidekiq::JobRetry::Skip) do
      handler.call(nil, probe_job, @queue) { raise Sidekiq::Job::Interrupted }
    end

    payloads = Sidekiq.redis { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }

    assert_equal 1, payloads.size
    assert_equal @token, JSON.parse(payloads.first)['jid']
  end

  def test_interrupt_skip
    handler = Sidekiq::Job::InterruptHandler.new
    handler.config = @config

    error = assert_raises(Sidekiq::JobRetry::Skip) do
      handler.call(nil, probe_job, @queue) { raise Sidekiq::Job::Interrupted }
    end

    assert_kind_of Sidekiq::JobRetry::Handled, error
  end

  # --- §10.3 Sidekiq::Metrics::Middleware -----------------------------------

  def test_metrics_cli_registration
    assert_subprocess(<<~RUBY)
      require "sidekiq/cli"
      chain = Sidekiq.default_configuration.server_middleware
      exit(chain.exists?(Sidekiq::Metrics::Middleware) ? 0 : 1)
    RUBY
  end

  def test_metrics_embedded_registration
    embedded = Sidekiq::Embedded.new(Sidekiq.default_configuration)

    assert embedded.config.server_middleware.exists?(Sidekiq::Metrics::Middleware)
    assert Sidekiq.default_configuration.default_capsule.server_middleware.exists?(Sidekiq::Metrics::Middleware)
  end

  # A failed execution still counts as an execution: `p` moves, `f` moves,
  # and the runtime does not (a failed job's runtime is noise).
  def test_metrics_failed_executions
    klass = "MetricsFailed#{@token}"
    at = ::Time.now.utc

    assert_raises(RuntimeError) { invoke_metrics(klass) { raise 'boom' } }

    totals = metric_totals(klass, at)

    assert_equal 1, totals['p']
  end

  def test_metrics_failures
    klass = "MetricsFailure#{@token}"
    at = ::Time.now.utc

    assert_raises(RuntimeError) { invoke_metrics(klass) { raise 'boom' } }

    totals = metric_totals(klass, at)

    assert_equal 1, totals['f']
  end

  def test_metrics_runtime
    klass = "MetricsRuntime#{@token}"
    at = ::Time.now.utc

    invoke_metrics(klass) { sleep 0.05 }

    totals = metric_totals(klass, at)

    assert_equal 1, totals['p']
    assert_operator totals['ms'], :>=, 10
  end

  # --- §10.3 Sidekiq::Middleware::I18n --------------------------------------

  def test_i18n_registration
    assert_subprocess(<<~RUBY)
      require "sidekiq/middleware/i18n"
      client = Sidekiq.default_configuration.client_middleware
      server = Sidekiq.default_configuration.server_middleware
      ok = client.exists?(Sidekiq::Middleware::I18n::Client) && server.exists?(Sidekiq::Middleware::I18n::Server)
      exit(ok ? 0 : 1)
    RUBY
  end

  # §10.3: `Sidekiq::Middleware::I18n::Client/Server` "persists `I18n.locale`
  # across job". The client middleware writes the locale into the job
  # payload; the server middleware restores it around the perform, so the job
  # observes the enqueueing process's locale.
  #
  # The worker's own locale is switched to English between the push and the
  # execution, so the locale the job sees can only come from the payload: a
  # server middleware that did nothing would leave the job on the worker's
  # locale and the round-trip assertions would fail. The locale the worker
  # had before the job is what the middleware restores afterwards.
  #
  # The stand-in for the i18n gem is installed for the duration of the block
  # and taken back down afterwards, and the middleware's own registration on
  # the process-global chains is taken back down with it: a `::I18n` or a
  # global I18n middleware that outlived the case would put a "locale" key
  # into the payload of every job this worker pushes.
  def test_i18n_locale
    global_before = global_i18n_entries

    with_i18n_middleware do
      assert_empty global_i18n_entries,
                   'the I18n middleware must not be registered on the global chains'

      @config.client_middleware.add(Sidekiq::Middleware::I18n::Client)
      @config.server_middleware.add(Sidekiq::Middleware::I18n::Server)
      build_capsule

      payload = nil
      with_fake_i18n(:fr) do
        push_probe
        payload = queued_payload

        # The worker runs under its own locale from here on.
        FakeI18n.locale = :en
        @processor.process_one

        assert_equal 'fr', Probe.entries.last[:locale],
                     'the job runs under the locale the payload carried'
        assert_equal :en, FakeI18n.locale,
                     'the server middleware restores the locale the worker had'
      end

      assert_equal 'fr', payload['locale'],
                   'the client middleware writes the locale into the payload'
    end

    assert_equal global_before.map { |chain, klass| [chain.object_id, klass] },
                 global_i18n_entries.map { |chain, klass| [chain.object_id, klass] },
                 'the global chains carry the same entries as before the case'
  end

  # --- §10.3 Sidekiq::CurrentAttributes --------------------------------------

  # The attributes change between the push and the execution: the job must
  # observe the values the payload carried, not the ones this thread holds
  # when it runs. A Load middleware that did nothing would leave the job on
  # the worker's own value.
  def test_current_attributes
    Sidekiq::CurrentAttributes.persist(ProbeAttributes, @config)
    build_capsule
    ProbeAttributes.probe_value = 'enqueued-value'

    push_probe
    ProbeAttributes.probe_value = 'worker-value'
    @processor.process_one

    assert_equal 'enqueued-value', Probe.entries.last[:first]['probe_value']
  end

  def test_current_save_registration
    Sidekiq::CurrentAttributes.persist(ProbeAttributes, @config)

    assert @config.client_middleware.exists?(Sidekiq::CurrentAttributes::Save)
  end

  def test_current_load_client
    Sidekiq::CurrentAttributes.persist(ProbeAttributes, @config)

    assert @config.client_middleware.exists?(Sidekiq::CurrentAttributes::Load)
  end

  def test_current_load_server
    Sidekiq::CurrentAttributes.persist(ProbeAttributes, @config)

    assert @config.server_middleware.exists?(Sidekiq::CurrentAttributes::Load)
  end

  def test_current_default_config
    Sidekiq::CurrentAttributes.persist(ProbeAttributes)

    default = Sidekiq.default_configuration

    assert default.client_middleware.exists?(Sidekiq::CurrentAttributes::Save)
    assert default.client_middleware.exists?(Sidekiq::CurrentAttributes::Load)
    assert default.server_middleware.exists?(Sidekiq::CurrentAttributes::Load)
  end

  # Same shape as the single-class case: both attribute classes change
  # between the push and the execution, so the job can only report the
  # serialized values if the Load middleware put them back.
  def test_current_multiple_classes
    Sidekiq::CurrentAttributes.persist([ProbeAttributes, SecondAttributes], @config)
    build_capsule
    ProbeAttributes.probe_value = 'one'
    SecondAttributes.second_value = 'two'

    push_probe
    ProbeAttributes.probe_value = 'one-after-push'
    SecondAttributes.second_value = 'two-after-push'
    @processor.process_one

    entry = Probe.entries.last

    assert_equal 'one', entry[:first]['probe_value']
    assert_equal 'two', entry[:second]['second_value']
  end

  def test_current_payload_keys
    Sidekiq::CurrentAttributes.persist([ProbeAttributes, SecondAttributes], @config)
    ProbeAttributes.probe_value = 'one'
    SecondAttributes.second_value = 'two'

    push_probe

    payload = queued_payload

    assert_equal 'one', payload['cattr']['probe_value']
    assert_equal 'two', payload['cattr_1']['second_value']
    refute payload.key?('cattr_2')
  end

  private

  # A cold process: the assertion is about what the documented require
  # registers, not about what this worker already loaded.
  def assert_subprocess(script)
    lib = File.expand_path('../../lib', __dir__)
    ok = system(RbConfig.ruby, *Wurk::Test::SUBPROCESS_COVERAGE, '-I', lib, '-e', script)

    assert ok, "subprocess failed:\n#{script}"
  end

  def probe_job
    { 'class' => 'ProbeJob', 'args' => [@token], 'jid' => @token, 'queue' => @queue }
  end

  # The capsule and the processor that run the probe job over real Redis.
  def build_capsule
    @capsule = Sidekiq::Capsule.new("builtin-parity-#{@token}", @config)
    @capsule.queues = [@queue]
    @capsule.fetcher = Sidekiq::BasicFetch.new(@capsule)
    @processor = Sidekiq::Processor.new(@capsule)
  end

  def push_probe
    Sidekiq::Client.new(config: @config).push('class' => ProbeJob, 'args' => [@token], 'queue' => @queue)
  end

  def queued_payload
    payloads = Sidekiq.redis { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }

    JSON.parse(payloads.first)
  end

  def invoke_metrics(klass, &)
    middleware = Sidekiq::Metrics::Middleware.new
    middleware.config = @config
    middleware.call(nil, { 'class' => klass }, @queue, &)
  end

  # The per-class counters the metrics middleware wrote, read back from the
  # minute buckets it writes ("<klass>|p", "<klass>|f", "<klass>|ms").
  def metric_totals(klass, at)
    Wurk::Metrics::History.flush
    keys = [at, at + 60].map { |time| Wurk::Metrics::History.minute_key(time.utc) }
    fields = %w[p f ms]
    values = Sidekiq.redis do |conn|
      keys.flat_map { |key| fields.map { |field| conn.call('HGET', key, "#{klass}|#{field}") } }
    end
    totals = Hash.new(0)
    values.each_with_index { |value, index| totals[fields[index % fields.size]] += value.to_i }

    totals
  end

  # The default-configuration case registers on the process-global chains;
  # take the registrations back down so the next test starts clean.
  def unregister_current_attributes
    default = Sidekiq.default_configuration
    default.client_middleware.remove(Sidekiq::CurrentAttributes::Save)
    default.client_middleware.remove(Sidekiq::CurrentAttributes::Load)
    default.server_middleware.remove(Sidekiq::CurrentAttributes::Load)
  end

  # Swap the top-level ::I18n for the stand-in for the duration of the block,
  # putting the real constant back afterwards.
  def with_fake_i18n(locale)
    had_real = Object.const_defined?(:I18n)
    real = had_real ? Object.const_get(:I18n) : nil
    Object.send(:remove_const, :I18n) if had_real
    Object.const_set(:I18n, FakeI18n)
    FakeI18n.locale = locale
    yield
  ensure
    Object.send(:remove_const, :I18n) if Object.const_defined?(:I18n)
    Object.const_set(:I18n, real) if had_real
  end

  # The I18n middleware file registers itself on the process-global chains.
  # That registration is taken back down for the duration of the block: the
  # middleware belongs to this test's own configuration, and a global
  # registration would put a "locale" key in the payload of every job this
  # worker pushes.
  def with_i18n_middleware
    before = global_i18n_entries
    require 'sidekiq/middleware/i18n'
    unregister_global_i18n
    yield
  ensure
    unregister_global_i18n
    before&.each { |chain, klass| chain.add(klass) }
  end

  def global_i18n_entries
    default = Sidekiq.default_configuration
    [default.client_middleware, default.server_middleware].flat_map do |chain|
      chain.entries.filter_map { |entry| [chain, entry.klass] if entry.klass.name.to_s.include?('I18n') }
    end
  end

  def unregister_global_i18n
    return unless defined?(Sidekiq::Middleware::I18n)

    default = Sidekiq.default_configuration
    default.client_middleware.remove(Sidekiq::Middleware::I18n::Client)
    default.server_middleware.remove(Sidekiq::Middleware::I18n::Server)
  end
end
