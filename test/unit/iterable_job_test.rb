# frozen_string_literal: true

require_relative '../test_helper'

# `cursor:` keyword is part of the build_enumerator contract; many tests
# don't read it but must still accept it. Disable the file-wide warning.
# rubocop:disable Lint/UnusedMethodArgument
class IterableJobTest < Wurk::Test::UnitCase
  parallelize_me!

  class SimpleIterable
    include Wurk::IterableJob

    def ran          = @ran ||= []
    def started      = @started ||= 0
    def completed    = @completed ||= 0
    attr_writer :started, :completed

    def build_enumerator(*_args, cursor:)
      start = cursor || 0
      Enumerator.new do |y|
        start.upto(2) { |i| y << [i, i + 1] }
      end
    end

    def each_iteration(item, *_args)
      ran << item
    end

    def on_start
      self.started = started + 1
    end

    def on_complete
      self.completed = completed + 1
    end
  end

  # --- error class ----------------------------------------------------

  def test_interrupted_inherits_runtime_error
    assert_operator Wurk::IterableJob::Interrupted, :<, RuntimeError
  end

  # --- worker DSL is mixed in -----------------------------------------

  def test_includes_job_dsl
    assert_respond_to SimpleIterable, :sidekiq_options
    assert_respond_to SimpleIterable, :perform_async
    assert_instance_of Wurk::Worker::Setter, SimpleIterable.set(queue: 'iter')
  end

  def test_jid_accessor_inherited_from_worker
    worker = SimpleIterable.new
    worker.jid = 'abc123'

    assert_equal 'abc123', worker.jid
  end

  # --- iteration_key --------------------------------------------------

  def test_iteration_key_uses_jid
    worker = SimpleIterable.new
    worker.jid = 'deadbeef'

    assert_equal 'it-deadbeef', worker.iteration_key
  end

  # --- method_added guard ---------------------------------------------

  def test_defining_perform_raises_at_method_added
    err = assert_raises(ArgumentError) do
      Class.new do
        include Wurk::IterableJob

        def perform(*); end
      end
    end

    assert_match(/IterableJob/, err.message)
    assert_match(/each_iteration/, err.message)
  end

  def test_defining_perform_in_subclass_also_raises
    parent = Class.new { include Wurk::IterableJob }

    assert_raises(ArgumentError) do
      Class.new(parent) do
        def perform(*); end
      end
    end
  end

  def test_defining_other_methods_does_not_raise
    klass = Class.new do
      include Wurk::IterableJob

      def helper; end
      def build_enumerator(*, cursor:); end
      def each_iteration(*); end
    end

    assert_respond_to klass.new, :helper
  end

  # --- defaults raise NotImplementedError -----------------------------

  def test_default_build_enumerator_raises
    klass = Class.new do
      include Wurk::IterableJob

      def each_iteration(*); end
    end

    err = assert_raises(NotImplementedError) { klass.new.perform }

    assert_match(/build_enumerator/, err.message)
  end

  def test_default_each_iteration_raises
    klass = Class.new do
      include Wurk::IterableJob

      def build_enumerator(*, cursor:)
        Enumerator.new { |y| y << [1, 1] }
      end
    end

    err = assert_raises(NotImplementedError) { klass.new.perform }

    assert_match(/each_iteration/, err.message)
  end

  # --- run loop -------------------------------------------------------

  def test_perform_drives_iterations_in_order
    worker = SimpleIterable.new
    worker.perform

    assert_equal [0, 1, 2], worker.ran
    assert_equal 1, worker.started
    assert_equal 1, worker.completed
  end

  class AroundTracer
    include Wurk::IterableJob

    def events = @events ||= []

    def build_enumerator(*, cursor:)
      Enumerator.new { |y| y << [42, 1] }
    end

    def each_iteration(item)
      events << [:run, item]
    end

    def around_iteration
      events << :before
      yield
      events << :after
    end
  end

  def test_around_iteration_wraps_each_call
    worker = AroundTracer.new
    worker.perform

    assert_equal [:before, [:run, 42], :after], worker.events
  end

  def test_arguments_returns_perform_args_during_iteration
    klass = Class.new do
      include Wurk::IterableJob

      attr_accessor :sink

      def build_enumerator(*, cursor:)
        Enumerator.new { |y| y << [1, 1] }
      end

      def each_iteration(_item, *)
        self.sink = arguments
      end
    end

    worker = klass.new
    worker.perform('a', 42)

    assert_equal ['a', 42], worker.sink
  end

  def test_arguments_defaults_to_empty_array
    assert_equal [], SimpleIterable.new.arguments
  end

  def test_current_object_set_during_iteration
    klass = Class.new do
      include Wurk::IterableJob

      def seen = @seen ||= []

      def build_enumerator(*, cursor:)
        Enumerator.new do |y|
          y << ['x', 1]
          y << ['y', 2]
        end
      end

      def each_iteration(_item)
        seen << current_object
      end
    end

    worker = klass.new
    worker.perform

    assert_equal %w[x y], worker.seen
  end

  def test_cursor_advances_to_last_yielded_value
    klass = Class.new do
      include Wurk::IterableJob

      def build_enumerator(*, cursor:)
        Enumerator.new do |y|
          y << [:a, 'cursor-1']
          y << [:b, 'cursor-2']
        end
      end

      def each_iteration(*); end
    end

    worker = klass.new
    worker.perform

    assert_equal 'cursor-2', worker.cursor
  end

  # --- cancellation ---------------------------------------------------

  def test_cancel_sets_cancelled_flag
    worker = SimpleIterable.new

    refute_predicate worker, :cancelled?
    worker.cancel!

    assert_predicate worker, :cancelled?
  end

  def test_perform_resets_cancellation_state_on_reuse
    worker = SimpleIterable.new
    worker.cancel!

    assert_predicate worker, :cancelled?

    worker.perform

    assert_equal [0, 1, 2], worker.ran
  end

  class SelfCancelling
    include Wurk::IterableJob

    def seen = @seen ||= []

    def build_enumerator(*, cursor:)
      Enumerator.new do |y|
        y << [1, 1]
        y << [2, 2]
      end
    end

    def each_iteration(item)
      seen << item
      cancel!
    end
  end

  def test_cancel_during_iteration_raises_interrupted_on_next_step
    worker = SelfCancelling.new

    assert_raises(Wurk::IterableJob::Interrupted) { worker.perform }
    assert_equal [1], worker.seen
  end
end
# rubocop:enable Lint/UnusedMethodArgument
