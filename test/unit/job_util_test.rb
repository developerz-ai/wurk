# frozen_string_literal: true

require_relative '../test_helper'
require 'date'
require 'stringio'

class JobUtilTest < Wurk::Test::UnitCase
  parallelize_me!

  STRICT_MUTEX = Wurk::Test::GLOBAL_STATE_MUTEX

  Host = Struct.new(:placeholder) do
    include Wurk::JobUtil
  end

  class StringLike < String; end

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

  # The walk dispatches on `val.class` through a compare_by_identity table, so a
  # subclass of a JSON-native type misses and is reported unsafe. Sidekiq
  # (job_util.rb:80-111) behaves identically — an ActiveSupport::SafeBuffer arg
  # raises there too — and the oracle is the contract.
  def test_verify_json_rejects_a_string_subclass_value
    with_strict_mode(:raise) do
      err = assert_raises(ArgumentError) { @host.verify_json({ 'class' => 'X', 'args' => [StringLike.new('hi')] }) }

      assert_match(/StringLike/, err.message)
    end
  end

  # Hash keys are the documented exception: Sidekiq checks them with `String ===`,
  # not the identity table, so a String subclass key stays acceptable.
  def test_verify_json_accepts_a_string_subclass_hash_key
    with_strict_mode(:raise) do
      @host.verify_json({ 'class' => 'X', 'args' => [{ StringLike.new('k') => 'v' }] })
    end
  end

  def test_verify_json_reports_the_first_offender_in_order
    with_strict_mode(:raise) do
      err = assert_raises(ArgumentError) { @host.verify_json({ 'class' => 'X', 'args' => [1, :first, Date.today] }) }

      assert_match(/:first is a Symbol/, err.message)
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

  # `client_class` is a permanent transient attribute (baked into the literal),
  # so we assert stripping directly — no global mutation, which previously
  # clobbered TRANSIENT_ATTRIBUTES for other suites under the parallel runner.
  def test_normalize_item_strips_transient_attributes
    item = @host.normalize_item({ 'class' => 'X', 'args' => [], 'queue' => 'q',
                                  'pool' => 'p', 'client_class' => 'TX' })

    refute item.key?('client_class')
    refute item.key?('pool')
  end

  # --- normalize_item: byte-identical payload shape (Plan 04/S8) -------
  #
  # Pins #normalize_item's output shape against the merge trim in
  # #normalize_item / #wrap_options (Plan 04/S7 — merge only when wrapping
  # actually applies): fewer intermediate Hash#merge calls must never change
  # which keys land in the final payload or their values. Six representative
  # shapes exercise every branch: bare class default, per-class
  # `get_sidekiq_options`, an explicit key overriding both, a `wrapped`
  # class (whose own options are shadowed once outer class defaults already
  # set `queue`/`retry` — verified against the real implementation, not
  # hand-derived), tags + `retry_for` coercion, and `at` + `expires_in`
  # stamping. `created_at` is excluded — it is a clock read, not merge output.
  def test_normalize_item_payload_shape_is_unchanged_for_representative_jobs
    jid = 'a' * 24
    cases = {
      plain_default: { 'class' => 'X', 'args' => [1, 2] },
      per_class_options: { 'class' => StubWorker, 'args' => [] },
      explicit_override: { 'class' => StubWorker, 'args' => [], 'queue' => 'override', 'retry' => false },
      wrapped_class: { 'class' => 'ActiveJob::Adapter', 'wrapped' => StubWorker, 'args' => [1] },
      with_tags_and_retry_for: { 'class' => 'X', 'args' => [], 'tags' => ['a'], 'retry_for' => '30' },
      with_expires_in_and_at: { 'class' => 'X', 'args' => [], 'at' => 2_000_000_000, 'expires_in' => 60 }
    }

    actual = cases.to_h do |name, item|
      item = item.merge('jid' => jid)
      [name, @host.normalize_item(item).except('created_at')]
    end

    expected = {
      plain_default: { 'retry' => true, 'queue' => 'default', 'class' => 'X', 'args' => [1, 2], 'jid' => jid },
      per_class_options: { 'queue' => 'critical', 'retry' => 5, 'class' => 'JobUtilTest::StubWorker',
                           'args' => [], 'jid' => jid },
      explicit_override: { 'queue' => 'override', 'retry' => false, 'class' => 'JobUtilTest::StubWorker',
                           'args' => [], 'jid' => jid },
      wrapped_class: { 'queue' => 'default', 'retry' => true, 'class' => 'ActiveJob::Adapter',
                       'wrapped' => StubWorker, 'args' => [1], 'jid' => jid },
      with_tags_and_retry_for: { 'retry' => true, 'queue' => 'default', 'class' => 'X', 'args' => [],
                                 'tags' => ['a'], 'retry_for' => 30, 'jid' => jid },
      with_expires_in_and_at: { 'retry' => true, 'queue' => 'default', 'class' => 'X', 'args' => [],
                                'at' => 2_000_000_000, 'expires_in' => 60, 'jid' => jid, 'expiry' => 2_000_000_060.0 }
    }

    assert_equal expected, actual
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

  STATE_MUTEX = Wurk::Test::GLOBAL_STATE_MUTEX

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
