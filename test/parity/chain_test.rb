# frozen_string_literal: true

require_relative '../test_helper'

# Parity oracle for `Sidekiq::Middleware::Chain` and its `Entry`, written from
# the documented promise in docs/target/sidekiq-free.md §10.1, not from Wurk's
# chain code.
#
# The chain is the documented contract a host leans on: what `add` appends,
# where `prepend`/`insert_before`/`insert_after` land, that `add` replaces an
# existing entry for the same class, that `retrieve` hands out fresh instances,
# and that `invoke` walks the chain inside-out and returns the block's result.
# Every assertion reads the chain's observable state — the entry list, the
# classes it names, the instances it builds — through the `Sidekiq::*` alias.
class ChainParityTest < Wurk::Test::UnitCase
  parallelize_me!

  # The order the chain entered and left each middleware in.
  module ChainLog
    MUTEX = Mutex.new
    @entries = []

    class << self
      def record(entry) = MUTEX.synchronize { @entries << entry }
      def entries = MUTEX.synchronize { @entries.dup }
      def clear = MUTEX.synchronize { @entries.clear }
    end
  end

  # Records the order in which the chain entered and left each middleware.
  class OrderRecorder
    include Sidekiq::ServerMiddleware

    def initialize(name)
      @name = name
    end

    def call(*)
      ChainLog.record("enter-#{@name}")
      result = yield
      ChainLog.record("exit-#{@name}")
      result
    end
  end

  # A second recorder class: `add` replaces the entry of the class it is given,
  # so a two-middleware chain needs two classes.
  class SecondOrderRecorder < OrderRecorder
  end

  # Keeps the arguments its constructor was handed, so `Entry#make_new` can be
  # observed through the instance it builds.
  class ArgsRecorder
    attr_reader :args

    def initialize(*args)
      @args = args
    end

    def call(*)
      yield
    end
  end

  # Carries the `config=` writer the chain injects into.
  class Configurable
    include Sidekiq::ServerMiddleware

    def call(*)
      yield
    end
  end

  # Carries no `config=` writer: the chain must leave it alone.
  class Plain
    def call(*)
      yield
    end
  end

  def setup
    super
    @chain = Sidekiq::Middleware::Chain.new
    ChainLog.clear
  end

  # --- §10.1 include Enumerable ---------------------------------------------

  def test_enumerable
    @chain.add(ArgsRecorder, :a)
    @chain.add(Plain)

    assert_kind_of Enumerable, @chain
    assert_equal [ArgsRecorder, Plain], @chain.map(&:klass)
    assert_equal 2, @chain.count
  end

  # --- §10.1 def initialize(config = nil) { |self| yield } -------------------

  def test_initialize_block
    yielded = nil
    chain = Sidekiq::Middleware::Chain.new(nil) do |c|
      yielded = c
      c.add(ArgsRecorder)
    end

    assert_same chain, yielded
    assert chain.exists?(ArgsRecorder)
  end

  # --- §10.1 def each(&) ----------------------------------------------------

  def test_each
    @chain.add(ArgsRecorder, :a)
    @chain.add(Plain)

    seen = @chain.each.to_a

    assert_equal @chain.entries, seen
  end

  # --- §10.1 def entries ----------------------------------------------------

  def test_entries
    @chain.add(ArgsRecorder, :a)
    @chain.add(Plain)

    assert_equal 2, @chain.entries.size
    assert_equal [ArgsRecorder, Plain], @chain.entries.map(&:klass)
  end

  # --- §10.1 def copy_for(capsule) ------------------------------------------

  def test_copy_for
    @chain.add(ArgsRecorder, :a)
    capsule = Sidekiq::Capsule.new('parity-chain', Sidekiq::Config.new)
    copy = @chain.copy_for(capsule)

    assert_equal [ArgsRecorder], copy.entries.map(&:klass)
    assert_same capsule, copy.config
    assert_same capsule, copy.entries.first.config

    copy.add(Plain)

    assert_equal [ArgsRecorder], @chain.entries.map(&:klass)
  end

  # --- §10.1 def add(klass, *args) — appends (removes existing first) --------

  def test_add_order
    @chain.add(ArgsRecorder, :a)
    @chain.add(Plain)

    assert_equal [ArgsRecorder, Plain], @chain.entries.map(&:klass)
  end

  def test_add_replaces
    @chain.add(ArgsRecorder, :a)
    @chain.add(Plain)
    @chain.add(ArgsRecorder, :b)

    assert_equal [Plain, ArgsRecorder], @chain.entries.map(&:klass)
    assert_equal 2, @chain.entries.size
  end

  # --- §10.1 def prepend(klass, *args) — adds at index 0 --------------------

  def test_prepend
    @chain.add(ArgsRecorder, :a)
    @chain.prepend(Plain, :b)

    assert_equal [Plain, ArgsRecorder], @chain.entries.map(&:klass)
  end

  # --- §10.1 def insert_before(oldklass, newklass, *args) -------------------

  def test_insert_before
    @chain.add(ArgsRecorder, :a)
    @chain.add(Plain)
    @chain.insert_before(ArgsRecorder, Configurable, :c)

    assert_equal [Configurable, ArgsRecorder, Plain], @chain.entries.map(&:klass)
  end

  # --- §10.1 def insert_after(oldklass, newklass, *args) --------------------

  def test_insert_after
    @chain.add(ArgsRecorder, :a)
    @chain.add(Plain)
    @chain.insert_after(ArgsRecorder, Configurable, :c)

    assert_equal [ArgsRecorder, Configurable, Plain], @chain.entries.map(&:klass)
  end

  # --- §10.1 def remove(klass) -----------------------------------------------

  def test_remove
    @chain.add(ArgsRecorder, :a)
    @chain.add(Plain)
    @chain.remove(ArgsRecorder)

    assert_equal [Plain], @chain.entries.map(&:klass)
  end

  # --- §10.1 def exists?(klass) — alias include? ----------------------------

  def test_exists
    refute @chain.exists?(ArgsRecorder)
    @chain.add(ArgsRecorder)

    assert @chain.exists?(ArgsRecorder)
  end

  def test_include
    @chain.add(ArgsRecorder)

    assert_equal @chain.exists?(ArgsRecorder), @chain.include?(ArgsRecorder)
    refute_includes @chain, Plain
  end

  # --- §10.1 def empty? -----------------------------------------------------

  def test_empty
    assert_empty @chain
    @chain.add(ArgsRecorder)

    refute_empty @chain
  end

  # --- §10.1 def retrieve — array of fresh instances ------------------------

  def test_fresh_instances
    @chain.add(ArgsRecorder, :a)

    first = @chain.retrieve
    second = @chain.retrieve

    assert_equal 1, first.size
    assert_instance_of ArgsRecorder, first.first
    refute_same first.first, second.first
  end

  # --- §10.1 def clear ------------------------------------------------------

  def test_clear
    @chain.add(ArgsRecorder, :a)
    @chain.add(Plain)
    @chain.clear

    assert_empty @chain.entries
    assert_empty @chain
  end

  # --- §10.1 def invoke(*args, &block) — runs chain; returns yield result ---

  def test_invoke_result
    @chain.add(OrderRecorder, :only)

    result = @chain.invoke(:payload) { :done }

    assert_equal :done, result
    assert_equal %w[enter-only exit-only], ChainLog.entries
  end

  def test_invoke_order
    @chain.add(OrderRecorder, :outer)
    @chain.add(SecondOrderRecorder, :inner)

    @chain.invoke { :ok }

    assert_equal %w[enter-outer enter-inner exit-inner exit-outer], ChainLog.entries
  end

  # --- §10.1 class Sidekiq::Middleware::Chain::Entry ------------------------

  def test_entry_class
    @chain.add(ArgsRecorder, :a)

    assert_equal ArgsRecorder, @chain.entries.first.klass
  end

  def test_entry_config
    @chain.add(ArgsRecorder, :a)
    entry = @chain.entries.first
    entry.config = :sentinel

    assert_equal :sentinel, entry.config
  end

  def test_entry_arguments
    @chain.add(ArgsRecorder, :one, :two)

    assert_equal %i[one two], @chain.retrieve.first.args
  end

  def test_config_injection
    config = Sidekiq::Config.new
    chain = Sidekiq::Middleware::Chain.new(config)
    chain.add(Configurable)
    chain.add(Plain)

    instances = chain.retrieve

    assert_same config, instances[0].config
    refute_respond_to instances[1], :config
  end
end
