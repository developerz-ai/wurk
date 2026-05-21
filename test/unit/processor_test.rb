# frozen_string_literal: true

require_relative '../test_helper'

# Drives Wurk::Processor against a real Reliable fetcher + real Redis. Each
# test owns a unique public queue/private list and a fresh job class so
# parallel runs can't collide on either Redis state or constant lookup.
class ProcessorTest < Wurk::Test::UnitCase
  parallelize_me!

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
    @processor = Wurk::Processor.new(@capsule)
    @dead_members = []
  end

  def teardown
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

  # --- middleware integration -----------------------------------------

  def test_server_middleware_runs_around_perform
    seen = []
    @capsule.server_middleware.add(recording_middleware_class, seen)
    klass = define_worker_appending(seen, :perform)
    enqueue(class: klass.name, args: [])

    @processor.process_one

    assert_equal %i[before perform after], seen
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
