# frozen_string_literal: true

require_relative '../test_helper'

class MiddlewareChainTest < Wurk::Test::UnitCase
  parallelize_me!

  # --- test middleware classes (no Redis, pure call chain) ---------------

  class Recorder
    attr_accessor :config

    def initialize(label, log)
      @label = label
      @log = log
    end

    def call(*_args, &block)
      @log << "#{@label}-pre"
      result = block.call
      @log << "#{@label}-post"
      result
    end
  end

  class Halter
    def initialize(log)
      @log = log
    end

    def call(*_args)
      @log << 'halter'
      false
    end
  end

  class NoConfig
    def initialize(*args)
      @args = args
    end

    def call(*_args)
      yield
    end
  end

  class Ensurer
    def initialize(label, log)
      @label = label
      @log = log
    end

    def call(*_args)
      yield
    ensure
      @log << "#{@label}-ensure"
    end
  end

  class ConfigProbe
    attr_accessor :config

    def initialize(log)
      @log = log
    end

    def call(*_args)
      @log << config
      yield
    end
  end

  class Identity
    def initialize(log)
      @log = log
    end

    def call(*_args)
      @log << self
      yield
    end
  end

  class WithConfig
    attr_accessor :config

    def call(*_args)
      yield
    end
  end

  # --- shape -------------------------------------------------------------

  def test_includes_enumerable
    assert_kind_of Enumerable, Wurk::Middleware::Chain.new
  end

  def test_initialize_yields_self
    yielded = nil
    chain = Wurk::Middleware::Chain.new { |c| yielded = c }

    assert_same chain, yielded
  end

  def test_initialize_accepts_config
    cfg = Object.new
    chain = Wurk::Middleware::Chain.new(cfg)

    assert_same cfg, chain.config
  end

  def test_default_entries_is_empty
    assert_predicate Wurk::Middleware::Chain.new, :empty?
    assert_empty Wurk::Middleware::Chain.new.entries
  end

  # --- add / prepend / remove --------------------------------------------

  def test_add_appends_entry
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig, :a)

    assert_equal 1, chain.entries.size
    assert_equal NoConfig, chain.entries.first.klass
  end

  def test_add_dedupes_existing_klass
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig, :first)
    chain.add(NoConfig, :second)

    assert_equal 1, chain.entries.size
    assert_equal [:second], chain.entries.first.instance_variable_get(:@args)
  end

  def test_prepend_inserts_at_head
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig)
    chain.prepend(WithConfig)

    assert_equal [WithConfig, NoConfig], chain.entries.map(&:klass)
  end

  def test_prepend_dedupes
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig)
    chain.add(WithConfig)
    chain.prepend(NoConfig)

    assert_equal [NoConfig, WithConfig], chain.entries.map(&:klass)
  end

  def test_remove_deletes_by_klass
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig)
    chain.add(WithConfig)
    chain.remove(NoConfig)

    assert_equal [WithConfig], chain.entries.map(&:klass)
  end

  def test_remove_missing_is_noop
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig)
    chain.remove(WithConfig)

    assert_equal [NoConfig], chain.entries.map(&:klass)
  end

  # --- insert_before / insert_after --------------------------------------

  def test_insert_before_places_ahead_of_target
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig)
    chain.add(WithConfig)
    chain.insert_before(WithConfig, Recorder)

    assert_equal [NoConfig, Recorder, WithConfig], chain.entries.map(&:klass)
  end

  def test_insert_before_relocates_existing_entry
    chain = Wurk::Middleware::Chain.new
    chain.add(Recorder)
    chain.add(NoConfig)
    chain.add(WithConfig)
    chain.insert_before(NoConfig, Recorder)

    assert_equal [Recorder, NoConfig, WithConfig], chain.entries.map(&:klass)
  end

  def test_insert_after_places_behind_target
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig)
    chain.add(WithConfig)
    chain.insert_after(NoConfig, Recorder)

    assert_equal [NoConfig, Recorder, WithConfig], chain.entries.map(&:klass)
  end

  # newklass already present: insert_after must relocate the existing entry
  # (the `delete_at(i)` arm of the ternary) rather than create a duplicate.
  def test_insert_after_relocates_existing_entry
    chain = Wurk::Middleware::Chain.new
    chain.add(Recorder)
    chain.add(NoConfig)
    chain.add(WithConfig)
    chain.insert_after(NoConfig, Recorder)

    assert_equal [NoConfig, Recorder, WithConfig], chain.entries.map(&:klass)
  end

  # oldklass absent: insert_after falls back to appending at the tail
  # (`|| (@entries.size - 1)` then +1), so the new entry lands last.
  def test_insert_after_appends_when_target_absent
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig)
    chain.insert_after(WithConfig, Recorder)

    assert_equal [NoConfig, Recorder], chain.entries.map(&:klass)
  end

  # --- exists? / include? / empty? ---------------------------------------

  def test_exists_predicate
    chain = Wurk::Middleware::Chain.new

    refute chain.exists?(NoConfig)
    chain.add(NoConfig)

    assert chain.exists?(NoConfig)
    assert_includes chain, NoConfig
  end

  def test_clear_empties_chain
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig)
    chain.add(WithConfig)
    chain.clear

    assert_predicate chain, :empty?
  end

  # --- retrieve / Entry#make_new -----------------------------------------

  def test_retrieve_builds_fresh_instances
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig, :x)

    a = chain.retrieve
    b = chain.retrieve

    assert_equal 1, a.size
    refute_same a.first, b.first
    assert_kind_of NoConfig, a.first
  end

  def test_retrieve_assigns_config_when_responds
    cfg = Object.new
    chain = Wurk::Middleware::Chain.new(cfg)
    chain.add(WithConfig)

    instance = chain.retrieve.first

    assert_same cfg, instance.config
  end

  def test_retrieve_skips_config_when_not_supported
    cfg = Object.new
    chain = Wurk::Middleware::Chain.new(cfg)
    chain.add(NoConfig)

    instance = chain.retrieve.first

    refute_respond_to instance, :config
  end

  def test_entry_passes_ctor_args_through
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig, :one, 2, 'three')

    instance = chain.retrieve.first

    assert_equal [:one, 2, 'three'], instance.instance_variable_get(:@args)
  end

  # Spec §10.1: `def make_new` — zero-argument. The entry carries the config
  # it was registered with, so a direct build resolves the chain's config
  # without the caller threading it back in.
  def test_entry_make_new_is_zero_argument_and_builds_with_the_registered_config
    cfg = Object.new
    chain = Wurk::Middleware::Chain.new(cfg)
    chain.add(WithConfig)
    entry = chain.entries.first

    assert_equal 0, entry.method(:make_new).arity

    instance = entry.make_new

    assert_kind_of WithConfig, instance
    assert_same cfg, instance.config
  end

  # A direct make_new follows the same respondable rule as retrieve: the
  # setter is found on the built instance even when only its singleton has it.
  def test_entry_make_new_assigns_config_to_a_singleton_only_setter
    cfg = Object.new
    klass = Class.new do
      def initialize = singleton_class.class_eval { attr_accessor :config }
      def call(*_args) = yield
    end
    chain = Wurk::Middleware::Chain.new(cfg)
    chain.add(klass)

    assert_same cfg, chain.entries.first.make_new.config
  end

  # The documented rule has no config-truthiness gate: a config-less chain
  # still assigns, so a recording writer sees nil rather than being skipped —
  # the `:unset` sentinel proves the writer ran (a skipped assignment would
  # leave it standing and fail this assert_nil).
  def test_entry_make_new_assigns_nil_when_the_chain_has_no_config
    klass = Class.new do
      def initialize = @assigned = :unset
      attr_reader :assigned

      def config=(value)
        @assigned = value
      end

      def call(*_args) = yield
    end
    chain = Wurk::Middleware::Chain.new
    chain.add(klass)

    assert_nil chain.entries.first.make_new.assigned
  end

  # --- invoke ------------------------------------------------------------

  def test_invoke_without_block_raises_argument_error
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig)

    assert_raises(ArgumentError) { chain.invoke('arg') }
  end

  def test_invoke_empty_chain_yields_block
    chain = Wurk::Middleware::Chain.new
    result = chain.invoke('arg') { :ok }

    assert_equal :ok, result
  end

  def test_invoke_runs_each_middleware_in_order
    log = []
    outer = Class.new(Recorder)
    inner = Class.new(Recorder)
    chain = Wurk::Middleware::Chain.new
    chain.add(outer, 'outer', log)
    chain.add(inner, 'inner', log)
    chain.invoke('arg') { log << 'body' }

    assert_equal %w[outer-pre inner-pre body inner-post outer-post], log
  end

  def test_invoke_returns_block_result
    chain = Wurk::Middleware::Chain.new
    chain.add(Recorder, 'a', [])
    result = chain.invoke('arg') { 42 }

    assert_equal 42, result
  end

  def test_invoke_halts_when_middleware_skips_yield
    log = []
    chain = Wurk::Middleware::Chain.new
    chain.add(Halter, log)
    body_ran = false
    chain.invoke('arg') { body_ran = true }

    refute body_ran
    assert_equal ['halter'], log
  end

  def test_invoke_forwards_args
    seen = []
    klass = Class.new do
      define_method(:initialize) { |bucket| @bucket = bucket }
      define_method(:call) do |*args, &block|
        @bucket << args
        block.call
      end
    end
    chain = Wurk::Middleware::Chain.new
    chain.add(klass, seen)
    chain.invoke(:a, :b, :c) { :done }

    assert_equal [%i[a b c]], seen
  end

  # The default server chain is six entries deep; the index walk has to hold
  # registration order (including prepend/insert_before repositioning) and
  # unwind in reverse.
  def test_invoke_walks_deep_chain_in_registration_order
    log = []
    chain = Wurk::Middleware::Chain.new
    labels = %w[a b c d e f]
    klasses = labels.to_h { |label| [label, Class.new(Recorder)] }
    labels.each { |label| chain.add(klasses[label], label, log) }
    chain.prepend(klasses['f'], 'f', log)
    chain.insert_before(klasses['b'], klasses['e'], 'e', log)
    chain.invoke('arg') { log << 'body' }

    assert_equal %w[f-pre a-pre e-pre b-pre c-pre d-pre body d-post c-post b-post e-post a-post f-post], log
  end

  def test_invoke_builds_fresh_instances_per_call
    seen = []
    chain = Wurk::Middleware::Chain.new
    chain.add(Identity, seen)
    2.times { chain.invoke('arg') { :ok } }

    assert_equal 2, seen.size
    refute_same seen[0], seen[1]
  end

  def test_invoke_propagates_exception_and_unwinds_in_reverse
    log = []
    chain = Wurk::Middleware::Chain.new
    chain.add(Class.new(Ensurer), 'outer', log)
    chain.add(Class.new(Ensurer), 'inner', log)

    assert_raises(RuntimeError) { chain.invoke('arg') { raise 'boom' } }
    assert_equal %w[inner-ensure outer-ensure], log
  end

  def test_invoke_halt_mid_chain_skips_downstream
    log = []
    chain = Wurk::Middleware::Chain.new
    chain.add(Class.new(Recorder), 'outer', log)
    chain.add(Halter, log)
    chain.add(Class.new(Recorder), 'never', log)
    chain.invoke('arg') { log << 'body' }

    assert_equal %w[outer-pre halter outer-post], log
  end

  def test_invoke_assigns_config_to_instances
    cfg = Object.new
    log = []
    chain = Wurk::Middleware::Chain.new(cfg)
    chain.add(ConfigProbe, log)
    chain.add(NoConfig)
    result = chain.invoke('arg') { :ok }

    assert_equal :ok, result
    assert_equal [cfg], log
  end

  # The class check taken at registration is a fast path, not the rule: the
  # contract is "assign config if the *instance* is respondable" (spec §10.1),
  # so a setter the class did not declare when it was added must still be seen.
  def test_config_is_assigned_when_the_setter_appears_after_registration
    cfg = Object.new
    klass = Class.new do
      def call(*_args) = yield
    end
    chain = Wurk::Middleware::Chain.new(cfg)
    chain.add(klass)
    klass.class_eval { attr_accessor :config }

    assert_same cfg, chain.retrieve.first.config
  end

  # A middleware that only grows the setter on its singleton (or reaches it
  # through method_missing) never answers `public_method_defined?`.
  def test_config_is_assigned_when_only_the_instance_responds
    cfg = Object.new
    klass = Class.new do
      def initialize = singleton_class.class_eval { attr_accessor :config }
      def call(*_args) = yield
    end
    chain = Wurk::Middleware::Chain.new(cfg)
    chain.add(klass)

    assert_same cfg, chain.retrieve.first.config
  end

  # The fast path must not invent a setter: a middleware with no `config=` at
  # all is built untouched, not crashed on.
  def test_config_is_not_assigned_when_nothing_responds
    chain = Wurk::Middleware::Chain.new(Object.new)
    chain.add(NoConfig)

    refute_respond_to chain.retrieve.first, :config=
  end

  # --- copy_for / dup ----------------------------------------------------

  def test_copy_for_returns_independent_chain
    parent = Wurk::Middleware::Chain.new
    parent.add(NoConfig)
    capsule = Object.new
    copy = parent.copy_for(capsule)

    assert_same capsule, copy.config
    assert_equal [NoConfig], copy.entries.map(&:klass)
  end

  def test_copy_for_mutations_do_not_affect_parent
    parent = Wurk::Middleware::Chain.new
    parent.add(NoConfig)
    copy = parent.copy_for(Object.new)
    copy.add(WithConfig)

    assert_equal [NoConfig], parent.entries.map(&:klass)
    assert_equal [NoConfig, WithConfig], copy.entries.map(&:klass)
  end

  # Entries carry their config, so copy_for duplicates each one and rebinds
  # only the duplicate: the capsule's middleware resolve the capsule while
  # the parent's entries keep the parent config (#69).
  def test_copy_for_rebinds_entry_configs_without_touching_the_parent
    parent_cfg = Object.new
    parent = Wurk::Middleware::Chain.new(parent_cfg)
    parent.add(WithConfig)
    capsule = Object.new
    copy = parent.copy_for(capsule)

    assert_same capsule, copy.entries.first.config
    assert_same parent_cfg, parent.entries.first.config
    assert_same capsule, copy.retrieve.first.config
  end

  def test_dup_creates_separate_entries_array
    a = Wurk::Middleware::Chain.new
    a.add(NoConfig)
    b = a.dup
    b.add(WithConfig)

    assert_equal [NoConfig], a.entries.map(&:klass)
    assert_equal [NoConfig, WithConfig], b.entries.map(&:klass)
  end

  # --- enumerable --------------------------------------------------------

  def test_each_iterates_entries
    chain = Wurk::Middleware::Chain.new
    chain.add(NoConfig)
    chain.add(WithConfig)
    klasses = chain.map(&:klass)

    assert_equal [NoConfig, WithConfig], klasses
  end
end
