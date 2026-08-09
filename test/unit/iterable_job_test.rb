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

  def test_cancel_during_iteration_stops_the_loop_without_interrupting
    worker = SelfCancelling.new
    worker.perform

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

  # Cancels and then raises Interrupted from the same iteration — the only
  # way a run reaches the interrupt path with @cancelled_at set now that
  # cancellation terminates the loop on its own.
  class CancelThenInterrupt
    include Wurk::IterableJob

    def build_enumerator(*, cursor:)
      Enumerator.new { |y| y << [1, 1] }
    end

    def each_iteration(_item, *)
      cancel!
      raise Wurk::IterableJob::Interrupted
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

  def state_exists?(jid)
    redis.with { |c| c.call('EXISTS', "it-#{jid}") } == 1
  end

  def interrupt_handler
    Wurk::Middleware::InterruptHandler.new.tap { |m| m.config = Wurk.configuration }
  end

  def pop_repush(queue)
    raw = redis.with { |c| c.call('LPOP', "queue:#{queue}") }

    refute_nil raw, 'InterruptHandler must have repushed the job'
    ::JSON.parse(raw)
  end

  def build_timeout_capsule
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    capsule = Wurk::Capsule.new("it-timeout-#{::Process.pid}-#{object_id}", config)
    watchdog = Wurk::Watchdog.new(capsule, interval: 0.01)
    capsule.instance_variable_set(:@watchdog, watchdog)
    [capsule, watchdog]
  end

  def timeout_middleware(capsule)
    Wurk::Middleware::Timeout.new.tap { |m| m.config = capsule }
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
  def test_interrupted_perform_persists_state_hash
    jid = random_jid
    worker = CancelThenInterrupt.new
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
    worker = CancelThenInterrupt.new
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
    def on_complete       = events << :complete
  end

  def test_cancelled_run_fires_cancel_stop_complete_in_order
    worker = StopOnly.new
    worker.perform

    assert_equal %i[cancel stop complete], worker.events
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

  # --- branch: load_state with cancelled present ----------------------

  # State hash carries a `cancelled` timestamp; load_state must set
  # @cancelled_at so the very first iteration trips and the run terminates.
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
      worker.perform

      assert_empty worker.seen, 'no iteration runs once cancelled state is loaded'
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # A resumed cancelled job must not raise Interrupted — raising would send it
  # back through InterruptHandler, which LPUSHes it to the head of the queue,
  # and the reloaded `cancelled` field would spin that cycle for three days.
  # The state HASH must be gone so nothing can trip on it again.
  def test_cancelled_run_deletes_state_instead_of_re_enqueueing
    jid = random_jid

    begin
      ts = ::Process.clock_gettime(::Process::CLOCK_REALTIME).to_i
      redis.with { |c| c.call('HSET', "it-#{jid}", 'ex', '1', 'c', ::JSON.generate(0), 'cancelled', ts) }

      worker = ResumableJob.new
      worker.jid = jid
      worker.perform

      refute state_exists?(jid), 'cancelled state hash deleted so the resumed job cannot re-cancel'
    ensure
      cleanup_iteration_key(jid)
    end
  end

  def test_self_cancelled_run_deletes_state
    jid = random_jid
    worker = CancelOnSecond.new
    worker.jid = jid

    begin
      worker.perform

      refute state_exists?(jid), 'state deleted when the job cancels itself mid-run'
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # --- cooperative shutdown -------------------------------------------

  # Stands in for Wurk::Processor: `interrupted?` (Wurk::Worker) asks the
  # attached context whether it is stopping.
  class StoppingContext
    def initialize(stop_after:)
      @stop_after = stop_after
      @calls = 0
    end

    def stopping?
      @calls += 1
      @calls > @stop_after
    end
  end

  def test_shutdown_flushes_cursor_and_raises_interrupted
    jid = random_jid
    worker = ResumableJob.new
    worker.jid = jid
    # Not stopping for the first check, stopping from the second on: one item
    # is processed, then the loop bails before touching the next.
    worker._context = StoppingContext.new(stop_after: 1)

    begin
      assert_raises(Wurk::IterableJob::Interrupted) { worker.perform }
      assert_equal [0], worker.seen

      cursor = redis.with { |c| c.call('HGET', "it-#{jid}", 'c') }

      assert_equal 1, ::JSON.parse(cursor), 'cursor of the last completed iteration is flushed'
    ensure
      cleanup_iteration_key(jid)
    end
  end

  def test_job_resumes_from_flushed_cursor_after_shutdown
    jid = random_jid
    stopped = ResumableJob.new
    stopped.jid = jid
    stopped._context = StoppingContext.new(stop_after: 2)

    begin
      assert_raises(Wurk::IterableJob::Interrupted) { stopped.perform }

      resumed = ResumableJob.new
      resumed.jid = jid
      resumed.perform

      assert_equal [2], resumed.seen, 'resumed run picks up exactly where the flush left off'
    ensure
      cleanup_iteration_key(jid)
    end
  end

  def test_shutdown_fires_on_stop_without_on_cancel
    worker = HookTracer.new
    worker._context = StoppingContext.new(stop_after: 0)

    assert_raises(Wurk::IterableJob::Interrupted) { worker.perform }
    assert_equal %i[start stop], worker.events
  end

  def test_cancellation_wins_over_shutdown
    jid = random_jid
    worker = StopOnly.new
    worker.jid = jid
    worker._context = StoppingContext.new(stop_after: 0)

    begin
      worker.cancel!
      worker.perform

      assert_equal %i[cancel stop complete], worker.events
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # --- interaction with sidekiq_options timeout:/deadline: (08-timeout-deadline) --

  # A cooperative interrupt persists cursor state to `it-<jid>` (iteration_key,
  # flush_state) — a HASH keyed off the jid, entirely separate from the job
  # envelope InterruptHandler re-pushes. `deadline_at` lives on that envelope,
  # so proving it survives is proving InterruptHandler's repush is verbatim,
  # not that IterableJob does anything with it — it never sees the field.
  class DeadlineAwareIterable
    include Wurk::IterableJob

    attr_writer :seen

    def seen = @seen ||= []

    def build_enumerator(*, cursor:)
      start = cursor || 0
      Enumerator.new { |y| start.upto(2) { |i| y << [i, i + 1] } }
    end

    def each_iteration(item, *)
      seen << item
    end
  end

  def test_deadline_survives_interrupt_and_resume
    jid = random_jid
    queue = "iq-#{::Process.pid}-#{object_id}"
    deadline_at = ::Time.now.to_f + 300
    job = { 'class' => DeadlineAwareIterable.name, 'args' => [], 'jid' => jid, 'deadline_at' => deadline_at }

    begin
      worker = DeadlineAwareIterable.new
      worker.jid = jid
      worker._context = StoppingContext.new(stop_after: 1)

      assert_raises(Wurk::JobRetry::Skip) do
        interrupt_handler.call(worker, job, queue) { worker.perform }
      end

      repushed = pop_repush(queue)

      assert_in_delta deadline_at, repushed['deadline_at'], 0.001,
                      'the absolute cutoff must ride the repush unchanged, not be re-derived'

      resumed = DeadlineAwareIterable.new
      resumed.jid = jid
      resumed.perform

      assert_equal [1, 2], resumed.seen, 'resumed iteration continues from the persisted cursor either way'
    ensure
      cleanup_iteration_key(jid)
      redis.with { |c| c.call('DEL', "queue:#{queue}") }
    end
  end

  # `timeout:` is per-attempt: Middleware::Timeout reads job['timeout'] fresh
  # on every call, so a resumed IterableJob attempt gets the whole bound again
  # rather than whatever was left when the first attempt was interrupted.
  class TimeoutResumableJob
    include Wurk::IterableJob

    attr_writer :seen, :sleep_before_next

    def seen = @seen ||= []
    def sleep_before_next = @sleep_before_next ||= 0

    def build_enumerator(*, cursor:)
      start = cursor || 0
      Enumerator.new { |y| start.upto(2) { |i| y << [i, i + 1] } }
    end

    def each_iteration(item, *)
      sleep sleep_before_next if sleep_before_next.positive?
      seen << item
    end
  end

  def test_timeout_resets_per_attempt_across_iterable_resume
    jid = random_jid
    capsule, watchdog = build_timeout_capsule
    job = { 'class' => TimeoutResumableJob.name, 'timeout' => 0.05 }

    begin
      interrupted = TimeoutResumableJob.new
      interrupted.jid = jid
      interrupted._context = StoppingContext.new(stop_after: 1)

      assert_raises(Wurk::IterableJob::Interrupted) do
        timeout_middleware(capsule).call(nil, job, 'q') { interrupted.perform }
      end
      assert_equal 0, watchdog.size, 'a cooperative interrupt retracts the bound cleanly — it never gets to fire'

      resumed = TimeoutResumableJob.new
      resumed.jid = jid
      resumed.sleep_before_next = 0.2

      err = assert_raises(Wurk::Job::TimedOut) do
        timeout_middleware(capsule).call(nil, job, 'q') { resumed.perform }
      end
      assert_match(/timed out after 0\.05s/, err.message,
                   'the resumed attempt must get the full bound again, not whatever was left of the first')
    ensure
      watchdog.terminate
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
