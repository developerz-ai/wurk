# frozen_string_literal: true

require_relative '../test_helper'

# A live worker's check of its own private list. The failure that matters here
# is the negative one: requeueing a job that is still running runs it twice, so
# most of these pin what must NOT move. Real Redis, real fetcher, real threads.
class FetcherSelfReconcileTest < Wurk::Test::UnitCase
  parallelize_me!

  # Parks inside `perform`; the gate is released by the test.
  class ParkedJob
    include Wurk::Job

    STARTED = Queue.new
    GATE = Queue.new

    def perform(_tag)
      STARTED << jid
      GATE.pop
    end
  end

  # Parks inside a Fiber: Thread#[] on this thread would now read the Fiber's
  # locals, not the ones the claim was written to.
  class ParkedInFiberJob
    include Wurk::Job

    STARTED = Queue.new
    GATE = Queue.new

    def perform(_tag)
      Fiber.new do
        STARTED << jid
        GATE.pop
      end.resume
    end
  end

  def setup
    super
    @queue_name = "reconcile-#{Process.pid}-#{object_id}"
    @public_queue = Wurk::Keys.queue(@queue_name)
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @capsule = @config.default_capsule
    @capsule.queues = [@queue_name]
    @capsule.fetcher = Wurk::Fetcher::Reliable.new(@capsule)
    @pool = @capsule.redis_pool
    @private_list = Wurk::Fetcher::Reliable.private_queue_name(@public_queue)
    @threads = []
  end

  def teardown
    @threads.each(&:kill)
    @pool.with { |c| c.call('DEL', @public_queue, @private_list) }
    @config.reset_redis_pools!
  ensure
    super
  end

  def test_a_stranded_payload_moves_only_on_its_second_sighting
    strand('lost')
    reconcile = build_reconcile

    assert_equal 0, reconcile.sweep, 'one sighting proves nothing'
    assert_equal ['lost'], in_private
    assert_equal 1, reconcile.sweep
    assert_empty in_private
    assert_equal ['lost'], in_public
  end

  def test_the_second_sighting_has_to_be_old_enough
    strand('lost')
    reconcile = build_reconcile(confirm: 60)

    3.times { assert_equal 0, reconcile.sweep }
    assert_equal ['lost'], in_private
  end

  def test_a_payload_that_stopped_being_stranded_starts_over
    strand('lost')
    reconcile = build_reconcile
    reconcile.sweep
    @pool.with { |c| c.call('DEL', @private_list) }
    reconcile.sweep
    strand('lost')

    assert_equal 0, reconcile.sweep, 'the earlier sighting was forgotten'
  end

  def test_a_running_job_never_moves
    jid = push(ParkedJob)
    processor = run_processor

    assert_equal jid, ParkedJob::STARTED.pop(timeout: 5)
    reconcile = build_reconcile

    5.times { assert_equal 0, reconcile.sweep }

    assert_equal 1, in_private.size
    assert_empty in_public
    ParkedJob::GATE << :go
    stop(processor)
  end

  def test_a_job_running_inside_a_fiber_never_moves
    jid = push(ParkedInFiberJob)
    processor = run_processor

    assert_equal jid, ParkedInFiberJob::STARTED.pop(timeout: 5)
    reconcile = build_reconcile

    5.times { assert_equal 0, reconcile.sweep }

    assert_equal 1, in_private.size
    ParkedInFiberJob::GATE << :go
    stop(processor)
  end

  def test_a_job_whose_ack_is_still_held_never_moves
    push_raw('finished')
    uow = @capsule.fetcher.retrieve_work
    uow.acknowledge
    uow.release_claim
    reconcile = build_reconcile

    5.times { assert_equal 0, reconcile.sweep }

    assert_equal ['finished'], in_private
    @capsule.fetcher.flush_pending_acks

    assert_empty in_private
  end

  # The order matters: list first, holders second. A claim landing between the
  # two has to read as held, on this sweep and every one after it.
  def test_a_claim_landing_between_the_read_and_the_check_never_moves
    strand('racing')
    unit = Wurk::Fetcher::Reliable::UnitOfWork.new(private_queue: @private_list, job: 'racing')
    reconcile = build_reconcile
    original = reconcile.method(:read)
    threads = @threads
    reconcile.define_singleton_method(:read) do |names|
      contents = original.call(names)
      threads << Thread.new do
        Thread.current.thread_variable_set(Wurk::Fetcher::Reliable::CLAIM_KEY, unit)
        sleep
      end
      sleep 0.01 until threads.last.thread_variable_get(Wurk::Fetcher::Reliable::CLAIM_KEY)
      contents
    end

    assert_equal 0, reconcile.sweep
    assert_empty reconcile.instance_variable_get(:@suspects), 'held by the time the holders were read'
    assert_equal ['racing'], in_private
  end

  # The window the second sweep exists for: claimed on the wire, not yet stamped
  # on a thread. The first sighting is suspicious, the stamp clears it.
  def test_a_unit_stamped_after_the_first_sighting_is_cleared_by_the_second
    strand('in-transit')
    reconcile = build_reconcile

    assert_equal 0, reconcile.sweep

    unit = Wurk::Fetcher::Reliable::UnitOfWork.new(private_queue: @private_list, job: 'in-transit')
    @threads << Thread.new do
      Thread.current.thread_variable_set(Wurk::Fetcher::Reliable::CLAIM_KEY, unit)
      sleep
    end
    wait_until { @threads.last.thread_variable_get(Wurk::Fetcher::Reliable::CLAIM_KEY) }

    3.times { assert_equal 0, reconcile.sweep }
    assert_equal ['in-transit'], in_private
  end

  # A client re-send can leave two byte-identical payloads. The running one must
  # not vouch for its twin, and the twin's move must not take the running one.
  def test_a_running_jobs_identical_twin_moves_and_the_running_copy_stays
    2.times { push_raw('twin') }
    gate = Queue.new
    claimed = Queue.new
    fetcher = @capsule.fetcher
    @threads << Thread.new do
      claimed << fetcher.retrieve_work
      gate.pop
    end
    claimed.pop(timeout: 5)
    @pool.with { |c| c.call('LMOVE', @public_queue, @private_list, 'RIGHT', 'LEFT') }
    reconcile = build_reconcile

    assert_equal 0, reconcile.sweep
    assert_equal 1, reconcile.sweep
    assert_equal ['twin'], in_private
    assert_equal ['twin'], in_public
    assert_equal 0, reconcile.sweep
  end

  def test_a_thread_that_died_holding_a_claim_stops_vouching_for_it
    push_raw('orphaned')
    fetcher = @capsule.fetcher
    Thread.new { fetcher.retrieve_work }.join
    reconcile = build_reconcile

    assert_equal 0, reconcile.sweep
    assert_equal 1, reconcile.sweep
    assert_equal ['orphaned'], in_public
  end

  def test_a_custom_fetcher_keeps_its_own_books
    strand('theirs')
    @capsule.fetcher = Object.new
    reconcile = build_reconcile

    2.times { assert_equal 0, reconcile.sweep }
    assert_equal ['theirs'], in_private
  end

  # A healthy process reads its lists' lengths and nothing else: no job payload
  # comes back over the wire to find out there is nothing to do.
  def test_a_healthy_sweep_does_not_read_the_payloads
    push_raw('running')
    fetcher = @capsule.fetcher
    claimed = Queue.new
    @threads << Thread.new do
      claimed << fetcher.retrieve_work
      sleep
    end
    claimed.pop(timeout: 5)
    reconcile = build_reconcile
    reconcile.define_singleton_method(:read) { |_names| raise 'read the payloads' }

    assert_equal 0, reconcile.sweep
  end

  def test_it_stops_at_the_stop_flag
    strand('a')
    strand('b')
    stopping = false
    reconcile = build_reconcile(stop: -> { stopping })
    reconcile.sweep
    stopping = true

    assert_equal 0, reconcile.sweep
    assert_equal 2, in_private.size
  end

  def test_a_move_is_handed_to_on_moved
    strand('lost')
    moved = []
    reconcile = build_reconcile(on_moved: ->(queue, payload) { moved << [queue, payload] })
    2.times { reconcile.sweep }

    assert_equal [[@public_queue, 'lost']], moved
  end

  private

  def build_reconcile(confirm: 0, **)
    Wurk::Fetcher::SelfReconcile.new(@config, confirm: confirm, **)
  end

  def strand(payload)
    @pool.with { |c| c.call('LPUSH', @private_list, payload) }
  end

  def push_raw(payload)
    @pool.with { |c| c.call('LPUSH', @public_queue, payload) }
  end

  def push(klass)
    jid = SecureRandom.hex(12)
    push_raw(Wurk.dump_json('class' => klass.name, 'args' => ['x'], 'jid' => jid,
                            'queue' => @queue_name, 'retry' => false))
    jid
  end

  def in_private = @pool.with { |c| c.call('LRANGE', @private_list, 0, -1) }
  def in_public = @pool.with { |c| c.call('LRANGE', @public_queue, 0, -1) }

  def run_processor
    processor = Wurk::Processor.new(@capsule) { nil }
    processor.start
    processor
  end

  def stop(processor)
    processor.terminate(true)
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    assert yield, 'condition never held'
  end
end
