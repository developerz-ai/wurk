# frozen_string_literal: true

require_relative '../test_helper'

# Drives Wurk::Processor against a real Reliable fetcher + real Redis. Each
# test owns a unique public queue/private list and a fresh job class so
# parallel runs can't collide on either Redis state or constant lookup.
class ProcessorTest < Wurk::Test::UnitCase
  parallelize_me!

  # Named (marshalable) non-StandardError so `run`'s `rescue Exception` path
  # fires without StandardError/Shutdown swallowing it earlier in the stack.
  class FatalBoom < Exception; end

  def setup
    super
    @queue_name = "pt-#{Process.pid}-#{object_id}"
    @public_queue = "#{Wurk::Keys::QUEUE_PREFIX}#{@queue_name}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @capsule = Wurk::Capsule.new('test', @config)
    @capsule.queues = [@queue_name]
    @capsule.fetcher = Wurk::Fetcher::Reliable.new(@capsule)
    @pool = @capsule.redis_pool
    @processors = []
    @processor = new_processor
    @dead_members = []
  end

  def teardown
    @processors.each { |p| stop_processor(p) }
    @pool.with do |conn|
      conn.call('DEL', @public_queue, private_queue)
      conn.call('ZREM', Wurk::Keys::DEAD, *@dead_members) unless @dead_members.empty?
    end
  ensure
    Wurk::Processor::PROCESSED.reset
    Wurk::Processor::FAILURE.reset
    Wurk::Processor::WORK_STATE.clear
    super
  end

  # --- initialization / lifecycle flags --------------------------------

  def test_initialize_sets_capsule_and_default_stopping_false
    assert_same @capsule, @processor.capsule
    refute_predicate @processor, :stopping?
  end

  def test_terminate_flips_stopping
    @processor.terminate

    assert_predicate @processor, :stopping?
  end

  def test_kill_flips_stopping_without_thread
    @processor.kill

    assert_predicate @processor, :stopping?
  end

  # terminate/kill with a live thread present exercise the non-nil branch
  # (line 42/53 else) and the wait true/false sides (line 44/56).

  def test_terminate_no_wait_with_thread_returns_immediately
    @processor.start
    @processor.terminate(false) # @done flips; loop exits between jobs

    assert_predicate @processor, :stopping?
    # join so the thread doesn't outlive the test (loop blocks up to the
    # fetcher's ~2s BLMOVE before noticing @done).
    @processor.thread.join(5)
  end

  def test_terminate_wait_true_joins_thread
    @processor.start
    @processor.terminate(true) # wait => @thread.value

    assert_predicate @processor, :stopping?
    refute_predicate @processor.thread, :alive?
  end

  def test_kill_no_wait_with_thread_raises_shutdown
    # Block inside perform so Wurk::Shutdown is raised within `process` (caught
    # by its `rescue Wurk::Shutdown`) rather than after `run` returns.
    klass = define_worker_blocking
    enqueue(class: klass.name, args: [])
    @processor.start
    klass.started_latch.pop
    @processor.kill(false) # raises Wurk::Shutdown into thread, no join

    assert_predicate @processor, :stopping?
    @processor.thread.join(2)
  end

  def test_kill_wait_true_joins_thread
    klass = define_worker_blocking
    enqueue(class: klass.name, args: [])
    @processor.start
    klass.started_latch.pop
    @processor.kill(true) # wait => @thread.value after raising Shutdown

    assert_predicate @processor, :stopping?
    refute_predicate @processor.thread, :alive?
  end

  # --- run loop callback (line 140 / 142 / 145, then + else of &.) -------

  def test_run_invokes_callback_on_clean_exit
    called = []
    processor = new_processor { |p| called << p }
    processor.start
    processor.terminate(true)

    assert_equal [processor], called
  end

  def test_run_without_callback_exits_cleanly
    processor = new_processor # nil callback => &. short-circuits
    processor.start
    processor.terminate(true)

    refute_predicate processor.thread, :alive?
  end

  # A Shutdown raised *during perform* is caught by `process`'s inner
  # `rescue Wurk::Shutdown` (it leaves the UoW un-acked) and `run` continues
  # to its clean exit. To exercise `run`'s own `rescue Wurk::Shutdown`
  # (line 141-142) the Shutdown must escape `process_one`, so stub it.

  def test_run_invokes_callback_on_shutdown
    called = []
    processor = new_processor { |_p| called << :shutdown }
    processor.define_singleton_method(:process_one) { raise Wurk::Shutdown }
    processor.start
    processor.thread.join(2)

    assert_equal [:shutdown], called
    refute_predicate processor.thread, :alive?
  end

  def test_run_without_callback_on_shutdown_exits_cleanly
    processor = new_processor # nil callback in Shutdown rescue
    processor.define_singleton_method(:process_one) { raise Wurk::Shutdown }
    processor.start
    processor.thread.join(2)

    refute_predicate processor.thread, :alive?
  end

  # In-flight Shutdown: caught by `process` (line 180), UoW stays in the
  # private list for reclaim on reboot — the documented two-stage kill.
  def test_kill_during_perform_leaves_uow_unacked
    klass = define_worker_blocking
    enqueue(class: klass.name, args: [])
    @processor.start
    klass.started_latch.pop
    @processor.kill(true)

    assert_equal 1, llen(private_queue), 'Shutdown mid-perform must not ack the UoW'
  end

  # run's `rescue Exception` re-raises after the callback. fetch and process
  # both swallow StandardError/Shutdown, so to hit line 143-146 we need a
  # non-StandardError, non-Shutdown error escaping process_one. Stub fetch to
  # raise such an error directly on the processor instance.

  def test_run_invokes_callback_then_reraises_on_fatal_error
    called = []
    processor = new_processor { |_p| called << :fatal }
    processor.define_singleton_method(:fetch) { raise FatalBoom, 'fatal' }
    processor.start
    # run re-raises (line 146); Thread#join propagates it to the caller.
    assert_raises(FatalBoom) { processor.thread.join(2) }

    assert_equal [:fatal], called
    refute_predicate processor.thread, :alive?
  end

  def test_run_without_callback_reraises_on_fatal_error
    processor = new_processor # nil callback in Exception rescue
    processor.define_singleton_method(:fetch) { raise FatalBoom, 'fatal' }
    processor.start
    assert_raises(FatalBoom) { processor.thread.join(2) }

    refute_predicate processor.thread, :alive?
  end

  # --- successful processing -------------------------------------------

  def test_process_one_runs_perform_and_acks
    klass = define_worker_recording
    enqueue(class: klass.name, args: [1, 'two', { 'k' => 'v' }])

    @processor.process_one

    assert_equal [1, 'two', { 'k' => 'v' }], klass.sink.first
    assert_equal 0, llen(private_queue), 'expected UoW to be acked'
    assert_equal 0, llen(@public_queue)
  end

  def test_process_one_assigns_jid_and_context_on_instance
    klass = define_worker_capturing_self
    enqueue(class: klass.name, args: [], jid: 'abc123')

    @processor.process_one

    captured = klass.sink.first

    assert_equal 'abc123', captured[:jid]
    assert_same @processor, captured[:ctx]
  end

  def test_process_one_records_perform_exception_in_retry_set_and_acks
    klass = define_worker_raising(RuntimeError, 'boom')
    payload = enqueue(class: klass.name, args: [], retry: true)

    @processor.process_one

    assert_equal 0, llen(private_queue), 'retrier handles → UoW must ack'
    # JobRetry ZADDs the rewritten payload into the canonical `retry` ZSET.
    found = @pool.with do |c|
      c.call('ZRANGE', Wurk::Keys::RETRY, 0, -1).find { |raw| raw.include?(%("jid":"#{payload['jid']}")) }
    end
    @pool.with { |c| c.call('ZREM', Wurk::Keys::RETRY, found) } if found

    refute_nil found, 'expected JobRetry to ZADD the failure into retry'
  end

  def test_process_one_acks_on_jobretry_handled
    klass = define_worker_raising(Wurk::JobRetry::Handled, 'handled')
    enqueue(class: klass.name, args: [])

    @processor.process_one

    assert_equal 0, llen(private_queue), 'Handled should be treated as a clean exit'
  end

  def test_process_one_acks_on_jobretry_skip
    klass = define_worker_raising(Wurk::JobRetry::Skip, 'skip')
    enqueue(class: klass.name, args: [])

    @processor.process_one

    assert_equal 0, llen(private_queue)
  end

  # --- malformed JSON --------------------------------------------------

  def test_process_one_routes_unparseable_payload_to_dead_set
    payload = "{not-json-#{@queue_name}"
    @dead_members << payload
    @pool.with { |c| c.call('LPUSH', @public_queue, payload) }

    @processor.process_one

    members = @pool.with { |c| c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1) }

    assert_includes members, payload
    assert_equal 0, llen(private_queue), 'parse-fail must still ack'
  end

  def test_process_one_does_not_raise_on_parse_fail
    payload = "definitely-not-json-#{@queue_name}"
    @dead_members << payload
    @pool.with { |c| c.call('LPUSH', @public_queue, payload) }

    @processor.process_one

    assert_equal 0, llen(private_queue)
  end

  # The malformed-JSON path routes through DeadSet#kill_raw, so it trims like
  # send_to_morgue does (spec §31.8: trim on every kill). A 1970-epoch entry is
  # far older than the default dead_timeout (180d) and must be evicted.
  def test_process_one_trims_dead_set_on_parse_fail
    ancient = "ancient-#{@queue_name}"
    @dead_members << ancient
    @pool.with { |c| c.call('ZADD', Wurk::Keys::DEAD, 1.0, ancient) }

    payload = "{still-not-json-#{@queue_name}"
    @dead_members << payload
    @pool.with { |c| c.call('LPUSH', @public_queue, payload) }

    @processor.process_one

    assert_includes @pool.with { |c| c.call('ZRANGE', Wurk::Keys::DEAD, 0, -1) }, payload
    assert_nil @pool.with { |c| c.call('ZSCORE', Wurk::Keys::DEAD, ancient) },
               'malformed-JSON path must trim expired dead entries'
  end

  # --- middleware integration -----------------------------------------

  def test_server_middleware_runs_around_perform
    seen = []
    @capsule.server_middleware.add(recording_middleware_class, seen)
    klass = define_worker_appending(seen, :perform)
    enqueue(class: klass.name, args: [])

    @processor.process_one

    assert_equal %i[before perform after], seen
  end

  def test_process_one_skips_bid_when_instance_lacks_setter
    # Worker mixes in `bid=`; undef it on this subclass so dispatch takes the
    # `respond_to?(:bid=)` == false branch (line 213 else).
    klass = define_worker_recording
    klass.send(:undef_method, :bid=)

    refute_respond_to klass.new, :bid=
    enqueue(class: klass.name, args: ['ok'], bid: 'B123')

    @processor.process_one

    assert_equal ['ok'], klass.sink.first
    assert_equal 0, llen(private_queue), 'job without bid= setter must still ack'
  end

  # --- counters / WORK_STATE ------------------------------------------

  def test_processed_counter_increments_on_success
    Wurk::Processor::PROCESSED.reset
    klass = define_worker_recording
    enqueue(class: klass.name, args: [])

    @processor.process_one

    assert_equal 1, Wurk::Processor::PROCESSED.reset
  end

  def test_failure_counter_increments_on_exception
    Wurk::Processor::FAILURE.reset
    klass = define_worker_raising(RuntimeError, 'x')
    payload = enqueue(class: klass.name, args: [], retry: true)

    @processor.process_one

    found = @pool.with do |c|
      c.call('ZRANGE', Wurk::Keys::RETRY, 0, -1).find { |raw| raw.include?(%("jid":"#{payload['jid']}")) }
    end
    @pool.with { |c| c.call('ZREM', Wurk::Keys::RETRY, found) } if found

    assert_equal 1, Wurk::Processor::FAILURE.reset
  end

  def test_work_state_populated_during_perform_and_cleared_after
    klass = define_worker_snapshotting_work_state
    enqueue(class: klass.name, args: [])

    @processor.process_one

    snap = klass.sink.first

    refute_empty snap
    assert_equal @queue_name, snap.values.first[:queue]
    assert_equal 0, Wurk::Processor::WORK_STATE.size
  end

  # --- Counter ---------------------------------------------------------

  def test_counter_increments_by_one_by_default
    c = Wurk::Processor::Counter.new

    assert_equal 1, c.incr
  end

  def test_counter_increments_by_amount
    c = Wurk::Processor::Counter.new
    c.incr(3)

    assert_equal 4, c.incr
  end

  def test_counter_reset_returns_value_and_zeroes
    c = Wurk::Processor::Counter.new
    c.incr(5)

    assert_equal 5, c.reset
    assert_equal 0, c.reset
  end

  def test_counter_is_thread_safe
    c = Wurk::Processor::Counter.new
    threads = Array.new(10) { Thread.new { 1_000.times { c.incr } } }
    threads.each(&:join)

    assert_equal 10_000, c.reset
  end

  # --- SharedWorkState -------------------------------------------------

  def test_shared_work_state_set_records_payload
    s = Wurk::Processor::SharedWorkState.new
    s.set('tid-1', queue: 'q', payload: 'p', run_at: 1)

    assert_equal({ queue: 'q', payload: 'p', run_at: 1 }, s.dup['tid-1'])
  end

  def test_shared_work_state_delete_removes_entry
    s = Wurk::Processor::SharedWorkState.new
    s.set('tid-1', queue: 'q', payload: 'p', run_at: 1)
    s.delete('tid-1')

    assert_equal 0, s.size
  end

  def test_shared_work_state_clear
    s = Wurk::Processor::SharedWorkState.new
    3.times { |i| s.set("tid-#{i}", queue: 'q', payload: 'p', run_at: i) }
    s.clear

    assert_equal 0, s.size
  end

  def test_shared_work_state_dup_is_a_snapshot
    s = Wurk::Processor::SharedWorkState.new
    s.set('a', x: 1)
    snap = s.dup
    s.set('b', x: 2)

    assert_equal %w[a], snap.keys
  end

  # --- compat ---------------------------------------------------------

  def test_aliased_under_sidekiq_namespace
    assert_same Wurk::Processor, Sidekiq::Processor
  end

  private

  def new_processor(&block)
    Wurk::Processor.new(@capsule, &block).tap { |p| @processors << p }
  end

  # `kill(true)` would block in `@thread.value` with no timeout, so teardown
  # asks for the raise only and does its own bounded wait below.
  def stop_processor(processor)
    processor.kill(false)
  rescue Exception # rubocop:disable Lint/RescueException
    nil
  ensure
    join_quietly(processor.thread)
  end

  # A few tests deliberately drive their processor's thread to die with
  # FatalBoom (a non-StandardError); #join re-raises that stored exception
  # every time it's called on the already-dead thread, so this rescues broadly
  # — a raising join still means the thread is gone. Only a join that times out
  # needs the Thread#kill fallback.
  def join_quietly(thread)
    return if thread.nil?
    return if thread.join(2)

    thread.kill
    thread.join(1)
  rescue Exception # rubocop:disable Lint/RescueException
    nil
  end

  def private_queue
    Wurk::Fetcher::Reliable.private_queue_name(@public_queue)
  end

  def enqueue(payload)
    payload = { 'jid' => SecureRandom.hex(6), 'queue' => @queue_name }.merge(payload.transform_keys(&:to_s))
    @pool.with { |c| c.call('LPUSH', @public_queue, Wurk.dump_json(payload)) }
    payload
  end

  def llen(key)
    @pool.with { |c| c.call('LLEN', key) }
  end

  # --- worker fixtures ------------------------------------------------
  # Each helper builds a one-off Worker subclass with a unique constant name
  # so parallel tests can't collide on Object.const_get lookup.

  def define_worker_recording
    klass = base_worker
    klass.class_eval do
      define_method(:perform) { |*args| self.class.sink << args }
    end
    klass
  end

  def define_worker_capturing_self
    klass = base_worker
    klass.class_eval do
      define_method(:perform) { self.class.sink << { jid: jid, ctx: @_context } }
    end
    klass
  end

  def define_worker_raising(error_class, message)
    klass = base_worker
    klass.define_singleton_method(:error_class) { error_class }
    klass.define_singleton_method(:error_message) { message }
    klass.class_eval do
      define_method(:perform) { |*| raise self.class.error_class, self.class.error_message }
    end
    klass
  end

  def define_worker_appending(sink, token)
    klass = base_worker
    klass.define_singleton_method(:external_sink) { sink }
    klass.define_singleton_method(:token) { token }
    klass.class_eval do
      define_method(:perform) { |*| self.class.external_sink << self.class.token }
    end
    klass
  end

  # Signals when perform starts, then blocks until Wurk::Shutdown is raised
  # into the thread. `started_latch.pop` lets the test wait for mid-flight.
  def define_worker_blocking
    klass = base_worker
    latch = Queue.new
    klass.define_singleton_method(:started_latch) { latch }
    klass.class_eval do
      define_method(:perform) do |*|
        self.class.started_latch << :started
        sleep
      end
    end
    klass
  end

  def define_worker_snapshotting_work_state
    klass = base_worker
    klass.class_eval do
      define_method(:perform) { |*| self.class.sink << Wurk::Processor::WORK_STATE.dup }
    end
    klass
  end

  # Fresh, uniquely-named Worker class with a class-level `sink` array.
  def base_worker
    klass = Class.new { include Wurk::Worker }
    klass.instance_variable_set(:@sink, [])
    klass.define_singleton_method(:sink) { @sink }
    Object.const_set(unique_worker_name, klass)
    klass
  end

  def unique_worker_name
    "PT_Worker_#{Process.pid}_#{object_id}_#{SecureRandom.hex(4)}"
  end

  # Records :before/:after around `yield` into the seeded sink array.
  def recording_middleware_class
    Class.new do
      include Wurk::Middleware::ServerMiddleware

      def initialize(sink)
        @sink = sink
      end

      def call(_instance, _job, _queue)
        @sink << :before
        yield
        @sink << :after
      end
    end
  end
end
