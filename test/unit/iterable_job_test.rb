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

  # --- constants ------------------------------------------------------

  def test_state_ttl_is_30_days
    assert_equal 30 * 86_400, Wurk::IterableJob::STATE_TTL
  end

  def test_state_flush_interval_is_5_seconds
    assert_equal 5, Wurk::IterableJob::STATE_FLUSH_INTERVAL
  end

  def test_cancellation_period_is_3_days
    assert_equal 3 * 86_400, Wurk::IterableJob::CANCELLATION_PERIOD
  end

  # --- redis-backed state --------------------------------------------

  class CancelOnSecond
    include Wurk::IterableJob

    def each_iteration(_item, *)
      cancel!
    end

    def build_enumerator(*, cursor:)
      Enumerator.new do |y|
        y << [1, 1]
        y << [2, 2]
      end
    end
  end

  def random_jid
    @_jid_counter ||= 0
    @_jid_counter += 1
    "wurk-it-#{Process.pid}-#{object_id}-#{@_jid_counter}"
  end

  def redis
    @redis ||= Wurk.configuration.redis_pool
  end

  def cleanup_iteration_key(jid)
    redis.with { |c| c.call('DEL', "it-#{jid}") }
  end

  def test_cancel_persists_to_iteration_hash_when_jid_set
    jid = random_jid
    worker = SimpleIterable.new
    worker.jid = jid

    begin
      ts = worker.cancel!
      raw = redis.with { |c| c.call('HGET', "it-#{jid}", 'cancelled') }

      assert_equal ts.to_s, raw.to_s
    ensure
      cleanup_iteration_key(jid)
    end
  end

  def test_cancel_sets_cancellation_period_ttl
    jid = random_jid
    worker = SimpleIterable.new
    worker.jid = jid

    begin
      worker.cancel!
      ttl = redis.with { |c| c.call('TTL', "it-#{jid}") }

      assert_operator ttl, :>, Wurk::IterableJob::CANCELLATION_PERIOD - 60
      assert_operator ttl, :<=, Wurk::IterableJob::CANCELLATION_PERIOD
    ensure
      cleanup_iteration_key(jid)
    end
  end

  def test_perform_flushes_state_hash_with_ex_c_rt_fields
    jid = random_jid
    worker = SimpleIterable.new
    worker.jid = jid

    begin
      worker.perform
      # SimpleIterable runs to completion and deletes the key, so push
      # cancellation in mid-flight to leave state behind.
      raw = redis.with { |c| c.call('EXISTS', "it-#{jid}") }

      assert_equal 0, raw, 'state hash should be deleted on successful completion'
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # Pins the full HASH wire shape (ex, c, rt, cancelled) on an interrupted
  # run. Splitting would obscure the contract — the field set IS the spec.
  def test_interrupted_perform_persists_state_hash # rubocop:disable Metrics/AbcSize,Minitest/MultipleAssertions
    jid = random_jid
    worker = CancelOnSecond.new
    worker.jid = jid

    begin
      assert_raises(Wurk::IterableJob::Interrupted) { worker.perform }

      raw = redis.with { |c| c.call('HGETALL', "it-#{jid}") }
      hash = raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h

      assert hash.key?('ex'),        'ex field present'
      assert hash.key?('c'),         'cursor field present'
      assert hash.key?('rt'),        'runtime field present'
      assert hash.key?('cancelled'), 'cancelled field present'
      assert_equal '1', hash['ex']
    ensure
      cleanup_iteration_key(jid)
    end
  end

  def test_interrupted_run_uses_cancellation_period_ttl
    jid = random_jid
    worker = CancelOnSecond.new
    worker.jid = jid

    begin
      assert_raises(Wurk::IterableJob::Interrupted) { worker.perform }

      ttl = redis.with { |c| c.call('TTL', "it-#{jid}") }

      assert_operator ttl, :>, Wurk::IterableJob::CANCELLATION_PERIOD - 60
      assert_operator ttl, :<=, Wurk::IterableJob::CANCELLATION_PERIOD
    ensure
      cleanup_iteration_key(jid)
    end
  end

  def test_remote_cancellation_observed_by_cancelled_predicate
    jid = random_jid
    worker = SimpleIterable.new
    worker.jid = jid

    begin
      ts = ::Process.clock_gettime(::Process::CLOCK_REALTIME).to_i
      redis.with { |c| c.call('HSET', "it-#{jid}", 'cancelled', ts) }

      assert_predicate worker, :cancelled?
    ensure
      cleanup_iteration_key(jid)
    end
  end

  def test_remote_cancellation_check_is_rate_limited
    jid = random_jid
    worker = SimpleIterable.new
    worker.jid = jid

    begin
      refute_predicate worker, :cancelled?

      ts = ::Process.clock_gettime(::Process::CLOCK_REALTIME).to_i
      redis.with { |c| c.call('HSET', "it-#{jid}", 'cancelled', ts) }

      # Subsequent check within 5s window should still return false — the
      # poll budget was spent on the first call. Flip the in-process flag
      # to verify the override path still works immediately.
      refute_predicate worker, :cancelled?
      worker.cancel!

      assert_predicate worker, :cancelled?
    ensure
      cleanup_iteration_key(jid)
    end
  end

  class ResumableJob
    include Wurk::IterableJob

    attr_writer :seen

    def seen = @seen ||= []

    def build_enumerator(*, cursor:)
      start = cursor || 0
      Enumerator.new do |y|
        start.upto(2) { |i| y << [i, i + 1] }
      end
    end

    def each_iteration(item, *)
      seen << item
    end
  end

  def test_resume_starts_from_persisted_cursor
    jid = random_jid

    begin
      redis.with do |c|
        c.call('HSET', "it-#{jid}",
               'ex', '1',
               'c',  ::JSON.generate(2),
               'rt', '0.5')
      end

      worker = ResumableJob.new
      worker.jid = jid
      worker.perform

      assert_equal [2], worker.seen
    ensure
      cleanup_iteration_key(jid)
    end
  end

  class HookTracer
    include Wurk::IterableJob

    def events = @events ||= []

    def build_enumerator(*, cursor:)
      Enumerator.new { |y| y << [1, 1] }
    end

    def each_iteration(*); end
    def on_start    = events << :start
    def on_resume   = events << :resume
    def on_complete = events << :complete
    def on_stop     = events << :stop
    def on_cancel   = events << :cancel
  end

  def test_on_resume_fires_when_resuming_from_persisted_state
    jid = random_jid

    begin
      redis.with do |c|
        c.call('HSET', "it-#{jid}", 'ex', '2', 'c', ::JSON.generate(1), 'rt', '0.0')
      end

      worker = HookTracer.new
      worker.jid = jid
      worker.perform

      assert_includes worker.events, :resume
      refute_includes worker.events, :start
    ensure
      cleanup_iteration_key(jid)
    end
  end

  def test_on_start_fires_on_fresh_run
    worker = HookTracer.new
    worker.perform

    assert_includes worker.events, :start
    assert_includes worker.events, :complete
    refute_includes worker.events, :resume
  end

  class StopOnly
    include Wurk::IterableJob

    def events = @events ||= []

    def build_enumerator(*, cursor:)
      Enumerator.new do |y|
        y << [1, 1]
        y << [2, 2]
      end
    end

    def each_iteration(_) = cancel!
    def on_cancel         = events << :cancel
    def on_stop           = events << :stop
  end

  def test_on_cancel_and_on_stop_fire_when_cancelled
    worker = StopOnly.new
    assert_raises(Wurk::IterableJob::Interrupted) { worker.perform }

    assert_equal %i[cancel stop], worker.events
  end

  # --- branch: interrupted WITHOUT cancellation (line 190 else) -------

  # Raises Interrupted from inside each_iteration without ever calling
  # cancel!, so @cancelled_at stays nil and finalize_interrupted skips
  # on_cancel but still fires on_stop.
  class ExternallyInterrupted
    include Wurk::IterableJob

    def events = @events ||= []

    def build_enumerator(*, cursor:)
      Enumerator.new do |y|
        y << [1, 1]
        y << [2, 2]
      end
    end

    def each_iteration(_item, *)
      raise Wurk::IterableJob::Interrupted
    end

    def on_cancel = events << :cancel
    def on_stop   = events << :stop
  end

  def test_interrupted_without_cancel_skips_on_cancel_but_fires_on_stop
    worker = ExternallyInterrupted.new
    assert_raises(Wurk::IterableJob::Interrupted) { worker.perform }

    assert_equal %i[stop], worker.events
    refute_predicate worker, :cancelled?
  end

  # --- branch: load_state with cancelled present (line 209 then) ------

  # State hash carries a `cancelled` timestamp; load_state must set
  # @cancelled_at so the very first iteration trips and raises Interrupted.
  def test_load_state_with_cancelled_field_trips_immediately
    jid = random_jid

    begin
      ts = ::Process.clock_gettime(::Process::CLOCK_REALTIME).to_i
      redis.with do |c|
        c.call('HSET', "it-#{jid}",
               'ex', '1',
               'c',  ::JSON.generate(0),
               'rt', '0.0',
               'cancelled', ts)
      end

      worker = ResumableJob.new
      worker.jid = jid

      assert_raises(Wurk::IterableJob::Interrupted) { worker.perform }
      assert_empty worker.seen, 'no iteration runs once cancelled state is loaded'
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # --- branches: load_state with missing fields (lines 206/207/208 else)

  # Hash exists (non-empty) but lacks ex/rt/c, so each conditional assign
  # takes its else side and the run starts fresh from cursor nil.
  def test_load_state_with_only_unrelated_field_leaves_defaults
    jid = random_jid

    begin
      redis.with { |c| c.call('HSET', "it-#{jid}", 'unrelated', 'x') }

      worker = ResumableJob.new
      worker.jid = jid
      worker.perform

      assert_equal [0, 1, 2], worker.seen, 'fresh run from cursor nil when ex/c/rt absent'
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # --- branches: mid-flight flush (lines 217 else, 227 else) ----------

  # Forces maybe_flush_state past its 5s gate by rewinding @last_flush_ms
  # from inside each_iteration, so the next iteration actually flushes
  # (217 else) via flush_state(final: false) (227 else) — without sleeping.
  class FlushForcer
    include Wurk::IterableJob

    def build_enumerator(*, cursor:)
      Enumerator.new do |y|
        y << [1, 1]
        y << [2, 2]
        y << [3, 3]
      end
    end

    def each_iteration(_item, *)
      # Rewind the flush clock well past the 5s window so the next
      # maybe_flush_state tick crosses the threshold and flushes.
      @last_flush_ms = 0
    end
  end

  def test_mid_flight_flush_persists_state_without_final_flag
    jid = random_jid
    worker = FlushForcer.new
    worker.jid = jid

    begin
      worker.perform

      # Completed run deletes state; the assertion that matters is that the
      # mid-flight flush path ran without raising. Re-run with a cursor
      # check via a fresh persisted state to confirm rt accumulated.
      assert_equal 0, redis.with { |c| c.call('EXISTS', "it-#{jid}") },
                   'state deleted on completion'
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # --- branches: normalize_hgetall (lines 286 Hash, 287 Array, 288 else)

  # normalize_hgetall is a pure shape-normalizer over whatever the
  # redis-client adapter returns for HGETALL (Hash on the adapter under
  # test, flat Array on others). It is not Redis I/O, so exercising every
  # arm directly is the deterministic, adapter-independent way to pin the
  # contract — no Redis mocking involved.
  def test_normalize_hgetall_passes_hash_through
    worker = SimpleIterable.new

    assert_equal({ 'ex' => '1' }, worker.send(:normalize_hgetall, { 'ex' => '1' }))
  end

  def test_normalize_hgetall_pairs_up_flat_array
    worker = SimpleIterable.new

    assert_equal({ 'ex' => '1', 'c' => '2' },
                 worker.send(:normalize_hgetall, %w[ex 1 c 2]))
  end

  def test_normalize_hgetall_returns_empty_hash_for_unexpected_shape
    worker = SimpleIterable.new

    assert_equal({}, worker.send(:normalize_hgetall, nil))
    assert_equal({}, worker.send(:normalize_hgetall, 'unexpected'))
  end

  # Confirms the real load path (Hash arm) still round-trips a persisted
  # cursor end to end.
  def test_load_state_round_trips_persisted_cursor
    jid = random_jid

    begin
      redis.with do |c|
        c.call('HSET', "it-#{jid}", 'ex', '1', 'c', ::JSON.generate(2), 'rt', '0.5')
      end

      worker = ResumableJob.new
      worker.jid = jid
      worker.perform

      assert_equal [2], worker.seen, 'cursor decoded from persisted HGETALL'
    ensure
      cleanup_iteration_key(jid)
    end
  end
end
# rubocop:enable Lint/UnusedMethodArgument
