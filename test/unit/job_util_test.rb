# frozen_string_literal: true

require_relative '../test_helper'
require 'date'
require 'stringio'

module WurkGlobalStateLock
  # One process-wide mutex serializing every test that mutates Wurk's
  # process-global state (`@default_job_options`, `@strict_args_mode`,
  # `@testing_mode`, `@server`). Without this, parallel classes holding
  # separate locks could interleave and corrupt shared state.
  MUTEX = Mutex.new
end

class JobUtilTest < Wurk::Test::UnitCase
  parallelize_me!

  STRICT_MUTEX = WurkGlobalStateLock::MUTEX

  Host = Struct.new(:placeholder) do
    include Wurk::JobUtil
  end

  # Sidekiq's public API names this `get_sidekiq_options` — wire-compat sacred.
  class StubWorker
    def self.get_sidekiq_options # rubocop:disable Naming/AccessorMethodName
      { 'queue' => 'critical', 'retry' => 5 }
    end
  end

  def setup
    super
    @host = Host.new(nil)
  end

  # --- validate --------------------------------------------------------

  def test_validate_requires_hash
    err = assert_raises(ArgumentError) { @host.validate(:not_a_hash) }
    assert_match(/Hash/, err.message)
  end

  def test_validate_requires_class_key
    assert_raises(ArgumentError) { @host.validate({ 'args' => [] }) }
  end

  def test_validate_requires_args_key
    assert_raises(ArgumentError) { @host.validate({ 'class' => 'X' }) }
  end

  def test_validate_args_must_be_array
    assert_raises(ArgumentError) { @host.validate({ 'class' => 'X', 'args' => 'oops' }) }
  end

  def test_validate_class_must_be_class_or_string
    assert_raises(ArgumentError) { @host.validate({ 'class' => 42, 'args' => [] }) }
  end

  def test_validate_at_must_be_numeric
    assert_raises(ArgumentError) { @host.validate({ 'class' => 'X', 'args' => [], 'at' => 'soon' }) }
  end

  def test_validate_tags_must_be_array
    assert_raises(ArgumentError) { @host.validate({ 'class' => 'X', 'args' => [], 'tags' => 'one' }) }
  end

  def test_validate_caps_retry_for_at_one_billion
    over = { 'class' => 'X', 'args' => [], 'retry_for' => Wurk::JobUtil::RETRY_FOR_MAX + 1 }
    assert_raises(ArgumentError) { @host.validate(over) }
  end

  def test_validate_rejects_non_numeric_retry_for
    bad = { 'class' => 'X', 'args' => [], 'retry_for' => 'abc' }
    assert_raises(ArgumentError) { @host.validate(bad) }
  end

  def test_validate_rejects_garbage_retry_for_object
    bad = { 'class' => 'X', 'args' => [], 'retry_for' => Object.new }
    assert_raises(ArgumentError) { @host.validate(bad) }
  end

  def test_validate_accepts_valid_item
    @host.validate({ 'class' => 'X', 'args' => [1, 'a'] })
  end

  def test_validate_accepts_class_value
    @host.validate({ 'class' => StubWorker, 'args' => [] })
  end

  # --- verify_json -----------------------------------------------------

  def test_verify_json_accepts_native_types
    with_strict_mode(:raise) do
      @host.verify_json({ 'class' => 'X', 'args' => [1, 'a', true, false, nil, 3.14, [1, 2], { 'k' => 'v' }] })
    end
  end

  def test_verify_json_raises_on_symbol_arg
    with_strict_mode(:raise) do
      err = assert_raises(ArgumentError) { @host.verify_json({ 'class' => 'X', 'args' => [:sym] }) }
      assert_match(/native JSON/, err.message)
    end
  end

  def test_verify_json_raises_on_symbol_keyed_hash
    with_strict_mode(:raise) do
      err = assert_raises(ArgumentError) { @host.verify_json({ 'class' => 'X', 'args' => [{ name: 'bob' }] }) }
      assert_match(/Symbol/, err.message)
    end
  end

  def test_verify_json_raises_on_date_arg
    with_strict_mode(:raise) do
      assert_raises(ArgumentError) { @host.verify_json({ 'class' => 'X', 'args' => [Date.today] }) }
    end
  end

  def test_verify_json_warn_mode_emits_to_logger
    with_strict_mode(:warn) do
      io = StringIO.new
      saved = Wurk.configuration.logger
      Wurk.configuration.logger = ::Logger.new(io)
      begin
        @host.verify_json({ 'class' => 'X', 'args' => [:bad] })
      ensure
        Wurk.configuration.logger = saved
      end

      assert_match(/native JSON/, io.string)
    end
  end

  def test_verify_json_false_mode_noops
    with_strict_mode(false) do
      io = StringIO.new
      saved = Wurk.configuration.logger
      Wurk.configuration.logger = ::Logger.new(io)
      begin
        @host.verify_json({ 'class' => 'X', 'args' => [:bad] })
      ensure
        Wurk.configuration.logger = saved
      end

      assert_empty io.string
    end
  end

  def test_verify_json_walks_nested_arrays
    with_strict_mode(:raise) do
      assert_raises(ArgumentError) { @host.verify_json({ 'class' => 'X', 'args' => [[1, [2, :nope]]] }) }
    end
  end

  def test_verify_json_walks_nested_hashes
    with_strict_mode(:raise) do
      assert_raises(ArgumentError) { @host.verify_json({ 'class' => 'X', 'args' => [{ 'k' => { 'inner' => :sym } }] }) }
    end
  end

  # --- normalize_item --------------------------------------------------

  def test_normalize_item_assigns_jid_as_24_hex
    item = @host.normalize_item({ 'class' => 'X', 'args' => [], 'queue' => 'default' })

    assert_match(/\A[0-9a-f]{24}\z/, item['jid'])
  end

  def test_normalize_item_assigns_created_at_in_millis
    item = @host.normalize_item({ 'class' => 'X', 'args' => [], 'queue' => 'default' })

    assert_kind_of Integer, item['created_at']
    assert_operator item['created_at'], :>, 1_700_000_000_000
  end

  def test_normalize_item_stringifies_class_constant
    item = @host.normalize_item({ 'class' => StubWorker, 'args' => [], 'queue' => 'default' })

    assert_equal 'JobUtilTest::StubWorker', item['class']
  end

  def test_normalize_item_stringifies_queue_symbol
    item = @host.normalize_item({ 'class' => 'X', 'args' => [], 'queue' => :high })

    assert_equal 'high', item['queue']
  end

  def test_normalize_item_merges_default_job_options
    item = @host.normalize_item({ 'class' => 'X', 'args' => [] })

    assert_equal 'default', item['queue']
    assert item['retry']
  end

  def test_normalize_item_prefers_per_class_options
    item = @host.normalize_item({ 'class' => StubWorker, 'args' => [] })

    assert_equal 'critical', item['queue']
    assert_equal 5, item['retry']
  end

  def test_normalize_item_explicit_keys_override_class_defaults
    item = @host.normalize_item({ 'class' => StubWorker, 'args' => [], 'queue' => 'override' })

    assert_equal 'override', item['queue']
  end

  def test_normalize_item_raises_when_queue_is_empty
    STRICT_MUTEX.synchronize do
      saved = Wurk.instance_variable_get(:@default_job_options)
      Wurk.instance_variable_set(:@default_job_options, { 'retry' => true, 'queue' => '' })
      begin
        assert_raises(ArgumentError) { @host.normalize_item({ 'class' => 'X', 'args' => [] }) }
      ensure
        Wurk.instance_variable_set(:@default_job_options, saved)
      end
    end
  end

  def test_normalize_item_rejects_symbol_keyed_input
    # Validate requires string keys — matches Sidekiq exactly. Callers
    # constructing payloads must use string keys; perform_async builds them.
    assert_raises(ArgumentError) { @host.normalize_item({ class: 'X', args: [], queue: 'q' }) }
  end

  def test_normalize_item_preserves_jid_when_provided
    item = @host.normalize_item({ 'class' => 'X', 'args' => [], 'queue' => 'q', 'jid' => 'preset' })

    assert_equal 'preset', item['jid']
  end

  def test_normalize_item_coerces_retry_for_to_int
    item = @host.normalize_item({ 'class' => 'X', 'args' => [], 'queue' => 'q', 'retry_for' => '60' })

    assert_equal 60, item['retry_for']
  end

  def test_normalize_item_strips_transient_attributes
    STRICT_MUTEX.synchronize do
      Wurk::JobUtil::TRANSIENT_ATTRIBUTES << 'client_class'
      begin
        item = @host.normalize_item({ 'class' => 'X', 'args' => [], 'queue' => 'q', 'client_class' => 'TX' })

        refute item.key?('client_class')
      ensure
        Wurk::JobUtil::TRANSIENT_ATTRIBUTES.delete('client_class')
      end
    end
  end

  # --- now_in_millis ---------------------------------------------------

  def test_now_in_millis_returns_integer
    assert_kind_of Integer, @host.now_in_millis
  end

  def test_now_in_millis_recent_epoch
    assert_operator @host.now_in_millis, :>, 1_700_000_000_000
  end

  private

  def with_strict_mode(mode)
    STRICT_MUTEX.synchronize do
      original = Wurk.strict_args_mode
      Wurk.strict_args!(mode)
      yield
    ensure
      Wurk.strict_args!(original)
    end
  end
end

class WurkTopLevelTest < Wurk::Test::UnitCase
  parallelize_me!

  STATE_MUTEX = WurkGlobalStateLock::MUTEX

  def test_shutdown_is_an_interrupt
    assert_operator Wurk::Shutdown, :<, Interrupt
  end

  def test_load_json_roundtrip
    assert_equal({ 'a' => 1, 'b' => [2, 3] }, Wurk.load_json('{"a":1,"b":[2,3]}'))
  end

  def test_dump_json_roundtrip
    assert_equal '{"a":1}', Wurk.dump_json({ 'a' => 1 })
  end

  def test_default_job_options_defaults
    assert Wurk.default_job_options['retry']
    assert_equal 'default', Wurk.default_job_options['queue']
  end

  def test_default_job_options_setter_merges_and_stringifies
    STATE_MUTEX.synchronize do
      saved = Wurk.instance_variable_get(:@default_job_options)
      begin
        Wurk.default_job_options = { backtrace: true }

        assert Wurk.default_job_options['backtrace']
        # original keys untouched
        assert_equal 'default', Wurk.default_job_options['queue']
      ensure
        Wurk.instance_variable_set(:@default_job_options, saved)
      end
    end
  end

  def test_strict_args_default_is_raise
    STATE_MUTEX.synchronize do
      saved_set = Wurk.instance_variable_defined?(:@strict_args_mode)
      saved = Wurk.instance_variable_get(:@strict_args_mode) if saved_set
      Wurk.remove_instance_variable(:@strict_args_mode) if saved_set
      begin
        assert_equal :raise, Wurk.strict_args_mode
      ensure
        Wurk.instance_variable_set(:@strict_args_mode, saved) if saved_set
      end
    end
  end

  def test_strict_args_setter_accepts_false
    STATE_MUTEX.synchronize do
      saved_set = Wurk.instance_variable_defined?(:@strict_args_mode)
      saved = Wurk.instance_variable_get(:@strict_args_mode) if saved_set
      begin
        Wurk.strict_args!(false)

        refute Wurk.strict_args_mode
      ensure
        if saved_set
          Wurk.instance_variable_set(:@strict_args_mode, saved)
        else
          Wurk.remove_instance_variable(:@strict_args_mode)
        end
      end
    end
  end

  def test_testing_bang_sets_and_returns_mode
    STATE_MUTEX.synchronize do
      Wurk.testing!(:inline)

      assert_predicate Wurk, :testing?
    ensure
      Wurk::Testing.disable!
    end
  end

  def test_testing_block_restores_after_yield
    STATE_MUTEX.synchronize do
      seen = nil
      Wurk.testing!(:fake) { seen = Wurk.testing? }

      assert seen
      refute_predicate Wurk, :testing?
    ensure
      Wurk::Testing.disable!
    end
  end

  def test_server_defaults_false
    refute_predicate Wurk, :server?
  end

  def test_server_setter
    STATE_MUTEX.synchronize do
      Wurk.server = true

      assert_predicate Wurk, :server?
    ensure
      Wurk.server = false
    end
  end

  def test_pro_always_false
    refute_predicate Wurk, :pro?
  end

  def test_ent_always_false
    refute_predicate Wurk, :ent?
  end
end
