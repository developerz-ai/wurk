# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/middleware/i18n'
require 'wurk/middleware/current_attributes'
require 'wurk/middleware/interrupt_handler'

# Coverage for the three built-in middleware modules. Each section runs the
# middleware in isolation — no Chain — so the assertions pin the contract
# of `#call` directly. Chain composition is exercised in middleware_chain_test.rb.
class MiddlewareBuiltinsTest < Wurk::Test::UnitCase
  parallelize_me!

  # --- fakes ---------------------------------------------------------------

  # Minimal I18n stand-in so we don't have to depend on the i18n gem.
  # Wurk::Middleware::I18n.with_locale checks `defined?(::I18n)` — `with_fake_i18n`
  # swaps a top-level `::I18n` constant for the duration of each test, saving
  # & restoring any real one that Rails may have loaded.
  module FakeI18n
    class << self
      attr_accessor :locale
    end
  end

  # Quacks like ActiveSupport::CurrentAttributes: `attributes` (Hash),
  # assignment writers, and `reset`.
  class FakeCurrent
    @attributes = {}

    class << self
      def attributes
        @attributes ||= {}
      end

      def user=(v)
        attributes[:user] = v
      end

      def tenant=(v)
        attributes[:tenant] = v
      end

      def reset
        @attributes = {}
      end
    end
  end

  class FakeCurrentTwo
    @attributes = {}

    class << self
      def attributes
        @attributes ||= {}
      end

      def request_id=(v)
        attributes[:request_id] = v
      end

      def reset
        @attributes = {}
      end
    end
  end

  class FakeConn
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(*args)
      @calls << args
    end
  end

  class FakePool
    attr_reader :conn

    def initialize
      @conn = FakeConn.new
    end

    def with
      yield @conn
    end
  end

  class FakeConfig
    attr_reader :redis_pool, :logger

    def initialize
      @redis_pool = FakePool.new
      @logger = ::Logger.new(IO::NULL)
    end

    def redis(&) = @redis_pool.with(&)
  end

  def setup
    super
    FakeCurrent.reset
    FakeCurrentTwo.reset
  end

  def with_fake_i18n(initial: :en)
    had_real = Object.const_defined?(:I18n)
    real     = had_real ? Object.const_get(:I18n) : nil
    Object.send(:remove_const, :I18n) if had_real
    Object.const_set(:I18n, FakeI18n)
    FakeI18n.locale = initial
    yield
  ensure
    Object.send(:remove_const, :I18n) if Object.const_defined?(:I18n)
    Object.const_set(:I18n, real) if had_real
  end

  # Ensures `::I18n` is undefined for the block, saving & restoring any
  # real constant Rails may have loaded. Mirror image of with_fake_i18n.
  def without_i18n
    had_real = Object.const_defined?(:I18n)
    real     = had_real ? Object.const_get(:I18n) : nil
    Object.send(:remove_const, :I18n) if had_real
    yield
  ensure
    Object.const_set(:I18n, real) if had_real
  end

  def build_handler
    h = Wurk::Middleware::InterruptHandler.new
    h.config = FakeConfig.new
    h
  end

  # =====================================================================
  # I18n
  # =====================================================================

  def test_i18n_client_writes_current_locale_into_job
    with_fake_i18n(initial: :fr) do
      job = { 'class' => 'X', 'args' => [] }
      Wurk::Middleware::I18n::Client.new.call('X', job, 'default', nil) { :body }

      assert_equal 'fr', job['locale']
    end
  end

  def test_i18n_client_preserves_caller_supplied_locale
    with_fake_i18n(initial: :fr) do
      job = { 'locale' => 'de' }
      Wurk::Middleware::I18n::Client.new.call('X', job, 'default', nil) { :body }

      assert_equal 'de', job['locale']
    end
  end

  def test_i18n_client_yields_and_returns_block_value
    with_fake_i18n do
      result = Wurk::Middleware::I18n::Client.new.call('X', {}, 'q', nil) { :ok }

      assert_equal :ok, result
    end
  end

  def test_i18n_server_scopes_locale_to_block
    with_fake_i18n(initial: :en) do
      seen = nil
      Wurk::Middleware::I18n::Server.new.call(nil, { 'locale' => 'es' }, 'q') do
        seen = FakeI18n.locale
      end

      assert_equal 'es', seen
      assert_equal :en, FakeI18n.locale, 'previous locale must be restored'
    end
  end

  def test_i18n_server_restores_locale_after_raise
    with_fake_i18n(initial: :en) do
      assert_raises(StandardError) do
        Wurk::Middleware::I18n::Server.new.call(nil, { 'locale' => 'ja' }, 'q') { raise StandardError }
      end
      assert_equal :en, FakeI18n.locale
    end
  end

  def test_i18n_server_is_noop_when_job_has_no_locale
    with_fake_i18n(initial: :en) do
      Wurk::Middleware::I18n::Server.new.call(nil, {}, 'q') { nil }

      assert_equal :en, FakeI18n.locale
    end
  end

  def test_i18n_includes_client_middleware_module
    assert_includes Wurk::Middleware::I18n::Client.ancestors, Wurk::Middleware::ClientMiddleware
    assert_includes Wurk::Middleware::I18n::Server.ancestors, Wurk::Middleware::ServerMiddleware
  end

  # No i18n gem loaded → `defined?(::I18n)` is false. current_locale must
  # return nil (the else side of `... if defined?(::I18n)`) so the client
  # never introduces a `"locale"` key and changes the wire shape.
  def test_i18n_current_locale_nil_when_not_loaded
    without_i18n do
      assert_nil Wurk::Middleware::I18n.current_locale
    end
  end

  def test_i18n_client_no_locale_key_when_i18n_absent
    without_i18n do
      job = { 'class' => 'X', 'args' => [] }
      result = Wurk::Middleware::I18n::Client.new.call('X', job, 'default', nil) { :body }

      refute_includes job.keys, 'locale'
      assert_equal :body, result
    end
  end

  # =====================================================================
  # CurrentAttributes
  # =====================================================================

  def test_current_attributes_save_snapshots_into_job_under_cattr
    FakeCurrent.user = 42
    job = {}
    Wurk::Middleware::CurrentAttributes::Save.new([FakeCurrent]).call('X', job, 'q', nil) { :body }

    assert_equal({ user: 42 }, job['cattr'])
  end

  def test_current_attributes_save_uses_indexed_keys_for_multi
    FakeCurrent.user = 1
    FakeCurrentTwo.request_id = 'r-1'
    job = {}
    Wurk::Middleware::CurrentAttributes::Save
      .new([FakeCurrent, FakeCurrentTwo])
      .call('X', job, 'q', nil) { :body }

    assert_equal({ user: 1 }, job['cattr'])
    assert_equal({ request_id: 'r-1' }, job['cattr_1'])
  end

  def test_current_attributes_save_does_not_overwrite_existing
    job = { 'cattr' => { user: 'preset' } }
    FakeCurrent.user = 'now'
    Wurk::Middleware::CurrentAttributes::Save.new([FakeCurrent]).call('X', job, 'q', nil) { :body }

    assert_equal({ user: 'preset' }, job['cattr'])
  end

  def test_current_attributes_load_restores_during_block
    seen = nil
    Wurk::Middleware::CurrentAttributes::Load
      .new([FakeCurrent])
      .call(nil, { 'cattr' => { user: 99 } }, 'q') do
        seen = FakeCurrent.attributes[:user]
      end

    assert_equal 99, seen
  end

  def test_current_attributes_load_resets_after_block
    Wurk::Middleware::CurrentAttributes::Load
      .new([FakeCurrent])
      .call(nil, { 'cattr' => { user: 99 } }, 'q') { :body }

    assert_empty FakeCurrent.attributes
  end

  def test_current_attributes_load_resets_after_raise
    assert_raises(StandardError) do
      Wurk::Middleware::CurrentAttributes::Load
        .new([FakeCurrent])
        .call(nil, { 'cattr' => { user: 99 } }, 'q') { raise StandardError }
    end
    assert_empty FakeCurrent.attributes
  end

  def test_current_attributes_load_indexed_restore
    seen_user = seen_req = nil
    Wurk::Middleware::CurrentAttributes::Load
      .new([FakeCurrent, FakeCurrentTwo])
      .call(nil, { 'cattr' => { user: 1 }, 'cattr_1' => { request_id: 'r' } }, 'q') do
        seen_user = FakeCurrent.attributes[:user]
        seen_req  = FakeCurrentTwo.attributes[:request_id]
      end

    assert_equal 1, seen_user
    assert_equal 'r', seen_req
  end

  def test_current_attributes_key_for
    assert_equal 'cattr',   Wurk::Middleware::CurrentAttributes.key_for(0)
    assert_equal 'cattr_1', Wurk::Middleware::CurrentAttributes.key_for(1)
    assert_equal 'cattr_2', Wurk::Middleware::CurrentAttributes.key_for(2)
  end

  def test_current_attributes_persist_registers_on_chains
    cfg = Wurk::Configuration.new
    Wurk::Middleware::CurrentAttributes.persist(FakeCurrent, cfg)

    assert cfg.client_middleware.exists?(Wurk::Middleware::CurrentAttributes::Save)
    # Load registers on BOTH chains per docs/target/sidekiq-free.md §10.3:
    # "adds Save to client_middleware, Load to client+server chains".
    assert cfg.client_middleware.exists?(Wurk::Middleware::CurrentAttributes::Load)
    assert cfg.server_middleware.exists?(Wurk::Middleware::CurrentAttributes::Load)
  end

  def test_current_attributes_persist_accepts_array
    cfg = Wurk::Configuration.new
    Wurk::Middleware::CurrentAttributes.persist([FakeCurrent, FakeCurrentTwo], cfg)

    assert cfg.client_middleware.exists?(Wurk::Middleware::CurrentAttributes::Save)
    assert cfg.server_middleware.exists?(Wurk::Middleware::CurrentAttributes::Load)
  end

  def test_current_attributes_persist_rejects_empty
    assert_raises(ArgumentError) do
      Wurk::Middleware::CurrentAttributes.persist([], Wurk::Configuration.new)
    end
  end

  # Load lives on the client chain too, which invokes with a 4th `redis_pool`
  # arg. Restore must still run when called with the client-chain arity.
  def test_current_attributes_load_accepts_client_chain_arity
    seen = nil
    Wurk::Middleware::CurrentAttributes::Load
      .new([FakeCurrent])
      .call('X', { 'cattr' => { user: 7 } }, 'q', nil) { seen = FakeCurrent.attributes[:user] }

    assert_equal 7, seen
  end

  # On the client chain an enqueue happens mid-request with attributes already
  # set; Load must restore that caller state afterward, not wipe it to empty.
  def test_current_attributes_load_restores_caller_state_after_enqueue
    FakeCurrent.user = 'request-scoped'

    Wurk::Middleware::CurrentAttributes::Load
      .new([FakeCurrent])
      .call('X', { 'cattr' => { user: 'job-snapshot' } }, 'q', nil) { :enqueued }

    assert_equal 'request-scoped', FakeCurrent.attributes[:user]
  end

  # #98: the documented drop-in constant is the top-level
  # `Sidekiq::CurrentAttributes`, aliased when the opt-in file is required.
  def test_sidekiq_current_attributes_alias
    assert_same Wurk::Middleware::CurrentAttributes, Sidekiq::CurrentAttributes
    assert_same Wurk::Middleware::CurrentAttributes::Save, Sidekiq::CurrentAttributes::Save
    assert_same Wurk::Middleware::CurrentAttributes::Load, Sidekiq::CurrentAttributes::Load
  end

  # =====================================================================
  # InterruptHandler
  # =====================================================================

  def test_interrupt_handler_passes_through_when_no_raise
    seen = build_handler.call(nil, { 'class' => 'X' }, 'q') { :ok }

    assert_equal :ok, seen
  end

  def test_interrupt_handler_does_not_repush_on_clean_run
    handler = build_handler
    handler.call(nil, { 'class' => 'X' }, 'q') { :ok }

    assert_empty handler.config.redis_pool.conn.calls
  end

  # One test pinning the entire repush wire shape (cmd, key, payload); split
  # would just obscure the contract.
  def test_interrupt_handler_repushes_on_interrupted
    handler = build_handler
    job = { 'class' => 'X', 'jid' => 'abc', 'args' => [1] }
    assert_raises(Wurk::JobRetry::Skip) do
      handler.call(nil, job, 'mine') { raise Wurk::Job::Interrupted }
    end

    calls = handler.config.redis_pool.conn.calls

    assert_equal 1, calls.size
    cmd, key, payload = calls.first

    assert_equal 'RPUSH', cmd
    assert_equal 'queue:mine', key
    assert_equal job, ::JSON.parse(payload)
  end

  def test_interrupt_handler_raises_skip_subclass_of_handled
    assert_operator Wurk::JobRetry::Skip, :<, Wurk::JobRetry::Handled
  end

  def test_interrupt_handler_rescues_iterable_job_alias_too
    # Wurk::IterableJob::Interrupted aliases Wurk::Job::Interrupted; the
    # handler must catch raises from either name with no special-casing.
    handler = build_handler
    assert_raises(Wurk::JobRetry::Skip) do
      handler.call(nil, { 'class' => 'X' }, 'q') { raise Wurk::IterableJob::Interrupted }
    end
  end

  def test_interrupt_handler_lets_other_exceptions_propagate
    handler = build_handler
    assert_raises(RuntimeError) do
      handler.call(nil, { 'class' => 'X' }, 'q') { raise 'boom' }
    end
    assert_empty handler.config.redis_pool.conn.calls
  end

  def test_interrupt_handler_module_inclusion
    assert_includes Wurk::Middleware::InterruptHandler.ancestors, Wurk::Middleware::ServerMiddleware
  end
end
