# frozen_string_literal: true

require_relative '../test_helper'

# What becomes of a global-concurrency slot after the fetch that took it:
# Processor#process's `ensure` as the release's only anchor, the heartbeat as
# its only refresh, and quiet as the deploy event that must not leave a
# draining worker sitting on capacity.
#
# Real Redis, a real Reliable fetcher under a real cap and a real Processor
# driven one job at a time. The release is a claim about unwind paths, and a
# stubbed fetch would only prove the stub unwinds.
#
# Parallel safety: the queue name is namespaced per test, so its public queue,
# private list and `queue_slot:` ZSET belong to it alone. Assertions read this
# test's own slot key and never `QueueSlot::HELD`'s size — that ledger is
# process-wide and sibling test threads keep holds of their own in it.
class QueueSlotLifecycleTest < Wurk::Test::UnitCase
  parallelize_me!

  # Captures what a caller queues onto a pipeline without opening one. Only for
  # the two tests that are about the *shape* of the beat's write; everything
  # else here goes through real Redis.
  class RecordingPipe
    attr_reader :calls

    def initialize = @calls = []

    def call(*args)
      @calls << args
      nil
    end
  end

  def setup
    super
    @queue_name = "qsl-#{Process.pid}-#{object_id}"
    @public_queue = "#{Wurk::Keys::QUEUE_PREFIX}#{@queue_name}"
    @slot_key = Wurk::Keys.queue_slot(@queue_name)
    @identity = "host-#{@queue_name}:1234"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:fetch_poll_interval] = 0.05
    @config.global_concurrency = { @queue_name => 1 }
    @capsule = Wurk::Capsule.new('test', @config)
    @capsule.queues = [@queue_name]
    @capsule.fetcher = Wurk::Fetcher::Reliable.new(@capsule)
    @pool = @capsule.redis_pool
    @pool.with { |conn| Wurk::Lua::Loader.script_load_all(conn) }
    @processor = Wurk::Processor.new(@capsule)
  end

  def teardown
    @capsule.watchdog&.terminate
    Wurk::QueueSlot::HELD.drop(Wurk::QueueSlot.token, @slot_key)
    @pool.with do |conn|
      conn.call('DEL', @public_queue, private_queue, @slot_key, @identity, "#{@identity}:work")
      conn.call('SREM', Wurk::Keys::PROCESSES, @identity)
      purge_job_sets(conn)
    end
  ensure
    Wurk::Processor::PROCESSED.reset
    Wurk::Processor::FAILURE.reset
    Wurk::Processor::WORK_STATE.clear
    super
  end

  # --- release on every exit path --------------------------------------

  def test_a_finished_job_gives_its_slot_back
    worker = worker_that { |sink| sink << holders }
    enqueue(worker)

    drive_one

    assert_equal [[Wurk::QueueSlot.token]], worker.sink, 'the job ran while holding the slot its fetch took'
    assert_empty holders
    assert_equal 0, llen(private_queue), 'a finished job is still acked'
  end

  # The `ensure` covers the arm the happy path never reaches: the job raised,
  # the retrier booked a retry and re-raised `Handled`, and the slot still has
  # to come back.
  def test_a_failed_job_gives_its_slot_back
    worker = worker_that { raise 'boom' }
    enqueue(worker)

    drive_one

    assert_empty holders
    assert_equal 1, retry_set_size, 'the failure really did take the retry path'
  end

  # Slice 08's bound is delivered by an async `Thread#raise` landing anywhere
  # inside `perform`, which is precisely the shape a release written into any
  # single rescue arm would miss.
  def test_a_job_cut_short_by_its_timeout_gives_its_slot_back
    @capsule.server_middleware { |chain| chain.add Wurk::Middleware::Timeout }
    @capsule.prepare!
    worker = worker_that { sleep 5 }
    worker.sidekiq_options timeout: 0.05
    enqueue(worker, 'timeout' => 0.05)

    drive_one

    assert_empty holders
    assert_equal 1, retry_set_size, 'a timeout is booked as the failure it is'
  end

  # The one path that deliberately does not ACK: the payload stays in the
  # private list to be re-run elsewhere, so the capacity whoever re-runs it
  # needs cannot wait out the TTL.
  def test_a_shutdown_gives_the_slot_back_without_acking_the_payload
    worker = worker_that { raise Wurk::Shutdown }
    enqueue(worker)

    drive_one

    assert_empty holders
    assert_equal 1, llen(private_queue), 'the payload is left for the reaper, exactly as before'
  end

  # A release that cannot reach Redis is reported, never raised: it runs inside
  # the ensure that the shutdown raise is already unwinding through, and a raise
  # from here would replace it and skip the rest of that unwind. The hold ages
  # out on its TTL instead.
  def test_a_release_that_cannot_reach_redis_is_reported_not_raised
    reported = []
    @config.error_handlers << ->(ex, ctx, _cfg) { reported << [ex.message, ctx[:context]] }
    capsule = @capsule
    worker = worker_that do
      capsule.define_singleton_method(:redis) { |**_o, &_b| raise 'redis is gone' }
      raise Wurk::Shutdown
    end
    enqueue(worker)

    @processor.process_one

    assert_equal [['redis is gone', 'Error releasing a queue slot']], reported
  ensure
    @capsule.singleton_class.remove_method(:redis) if @capsule.singleton_class.method_defined?(:redis)
  end

  # parse_or_kill ACKs and returns before #process's begin/ensure is ever
  # entered — the release rides that ACK rather than needing an arm of its own.
  def test_a_malformed_payload_gives_the_slot_back_with_its_ack
    push_raw("not json #{@queue_name}")

    drive_one

    assert_empty holders
    assert_equal 0, llen(private_queue)
    assert_equal 1, dead_set_size, 'the malformed payload still reached the morgue'
  end

  # --- what the release costs ------------------------------------------

  # Deferred, exactly like the ACK it rides: the ZREM is written into the
  # pipeline the next fetch opens, so giving a slot back costs no round trip.
  def test_the_release_waits_for_the_ack_it_rides_rather_than_taking_a_round_trip
    worker = worker_that { nil }
    enqueue(worker)

    @processor.process_one

    assert_equal [Wurk::QueueSlot.token], holders,
                 'the hold is still in Redis until the ACK carrying its ZREM goes out'

    @capsule.fetcher.flush_pending_acks

    assert_empty holders
  end

  # The property the cap is for: once released, the capacity is genuinely
  # available to another host, not merely forgotten locally.
  def test_a_released_slot_is_claimable_by_another_holder
    worker = worker_that { nil }
    enqueue(worker)

    drive_one

    assert Wurk::QueueSlot.acquire(@queue_name, capacity: 1, token: 'another-host:1', pool: @pool)
  end

  # A capped queue already known to be at capacity is skipped without a round
  # trip, so a pass that skips every queue never hands its ACK to anything —
  # and the thread would park in BLMOVE still holding the slot its last job ran
  # under. Idle, and spending capacity somebody else could use.
  #
  # The gate is closed by hand because that is the real shape: gates are shared
  # by a capsule's processor threads, so the refusal this thread backs off on is
  # usually one a sibling heard.
  def test_a_thread_about_to_park_does_not_keep_the_capacity_its_last_job_used
    enqueue(worker_that { nil })
    @processor.process_one
    close_gate!

    assert_equal [Wurk::QueueSlot.token], holders

    @capsule.fetcher.retrieve_work

    assert_empty holders, 'the parked thread flushed its release before blocking'
  end

  # --- quiet ------------------------------------------------------------

  # Quiet is one-way and stops the fetching that would otherwise carry the ACK,
  # so it is the fetcher's own flush that has to hand the slot back.
  def test_quiet_flushes_the_release_a_drained_worker_is_holding
    worker = worker_that { nil }
    enqueue(worker)
    @processor.process_one

    assert_equal [Wurk::QueueSlot.token], holders

    @capsule.fetcher.terminate

    assert_empty holders
  end

  # A quieted capsule keeps exactly the slots its still-running jobs are
  # spending — it stops taking new ones and gives back the ones it finished.
  def test_a_quieted_capsule_takes_no_further_slots
    @capsule.fetcher.terminate
    enqueue(worker_that { nil })

    assert_nil @capsule.fetcher.retrieve_work
    assert_empty holders
    assert_equal 1, llen(@public_queue), 'the job stayed on the queue'
  end

  # --- the ledger the heartbeat refreshes from --------------------------

  def test_a_capped_claim_registers_the_hold_the_beat_refreshes
    enqueue(worker_that { nil })
    @capsule.fetcher.retrieve_work

    assert_equal @slot_key, Wurk::QueueSlot::HELD.snapshot[Wurk::QueueSlot.token]
  end

  def test_a_release_takes_the_hold_off_the_ledger
    enqueue(worker_that { nil })
    drive_one

    assert_nil Wurk::QueueSlot::HELD.snapshot[Wurk::QueueSlot.token]
  end

  # A release can arrive after the same thread has claimed a slot on another
  # queue — a flush that failed and was retried. Dropping by token alone would
  # then stop refreshing the hold that is actually live.
  def test_the_ledger_drops_only_the_hold_it_names
    ledger = Wurk::QueueSlot::Held.new
    ledger.hold('t1', 'queue_slot:a')
    ledger.drop('t1', 'queue_slot:b')

    assert_equal({ 't1' => 'queue_slot:a' }, ledger.snapshot)
    assert_equal 1, ledger.size

    ledger.drop('t1', 'queue_slot:a')

    assert_empty ledger.snapshot
  end

  # --- heartbeat refresh -------------------------------------------------

  def test_the_beat_extends_a_hold_this_process_is_still_using
    Wurk::QueueSlot.acquire(@queue_name, capacity: 1, ttl: 3, pool: @pool)
    Wurk::QueueSlot::HELD.hold(Wurk::QueueSlot.token, @slot_key)
    before = hold_expiry

    build_heartbeat.beat!

    assert_operator hold_expiry, :>, before + Wurk::QueueSlot::TTL_SECONDS - 5,
                    'the beat pushed the hold a full TTL out, not a fraction of one'
  end

  # ZADD XX. A hold that already aged out has had its capacity handed on, so
  # re-adding the member would put the queue over its cap with two holders that
  # each believe the slot is theirs.
  def test_the_beat_does_not_resurrect_a_hold_that_already_expired
    @pool.with { |conn| conn.call('ZADD', @slot_key, Time.now.to_i - 5, Wurk::QueueSlot.token) }
    @pool.with { |conn| conn.call('ZREMRANGEBYSCORE', @slot_key, '-inf', Time.now.to_f.to_s) }
    Wurk::QueueSlot::HELD.hold(Wurk::QueueSlot.token, @slot_key)

    build_heartbeat.beat!

    assert_empty holders
  end

  # A pipelined EVALSHA surfaces NOSCRIPT only when the pipeline finalizes, so
  # without the reload-and-replay arm a flushed script cache costs this process
  # every beat until some other caller happens to reload — and a hold that stops
  # being refreshed is capacity that evaporates under a running job.
  def test_a_flushed_script_cache_does_not_cost_the_beat_its_refresh
    Wurk::QueueSlot.acquire(@queue_name, capacity: 1, ttl: 3, pool: @pool)
    Wurk::QueueSlot::HELD.hold(Wurk::QueueSlot.token, @slot_key)
    before = hold_expiry
    @pool.with { |conn| conn.call('SCRIPT', 'FLUSH') }

    refute_nil build_heartbeat.beat!, 'the beat landed rather than falling into its rescue'
    assert_operator hold_expiry, :>, before + Wurk::QueueSlot::TTL_SECONDS - 5
  end

  # Every hold rides one call, so a process running N capped jobs beats with the
  # same command count as one running a single job.
  def test_the_refresh_is_one_call_however_many_slots_are_held
    Wurk::QueueSlot::HELD.hold(Wurk::QueueSlot.token, @slot_key)
    pipe = RecordingPipe.new

    Wurk::QueueSlot.refresh_in(pipe)

    assert_equal 1, pipe.calls.size
    queued = pipe.calls.first

    assert_equal 'EVALSHA', queued.first
    assert_equal Wurk::Lua::SHAS[:refresh_slots], queued[1]
    assert_includes queued, @slot_key
    assert_includes queued, Wurk::QueueSlot.token
  end

  private

  def drive_one
    @processor.process_one
    @capsule.fetcher.flush_pending_acks
  end

  def build_heartbeat
    Wurk::Heartbeat.new(identity: @identity, config: @config)
  end

  def holders
    @pool.with { |conn| conn.call('ZRANGE', @slot_key, 0, -1) }
  end

  def hold_expiry
    @pool.with { |conn| conn.call('ZSCORE', @slot_key, Wurk::QueueSlot.token) }.to_f
  end

  # Put the queue's gate into the backoff a refusal leaves behind, without
  # having to arrange a real one.
  def close_gate!
    gate = @capsule.fetcher.send(:gate_for, @public_queue)
    gate.block!(::Process.clock_gettime(::Process::CLOCK_MONOTONIC))
  end

  def private_queue = Wurk::Fetcher::Reliable.private_queue_name(@public_queue)

  def llen(key) = @pool.with { |conn| conn.call('LLEN', key) }

  def retry_set_size = zset_members(Wurk::Keys::RETRY).size

  def dead_set_size = zset_members(Wurk::Keys::DEAD).size

  # Only this test's own members: `retry` and `dead` are global keys shared with
  # every sibling running in the same worker's Redis DB.
  def zset_members(key)
    @pool.with { |conn| conn.call('ZRANGE', key, 0, -1) }.select { |m| m.include?(@queue_name) }
  end

  def purge_job_sets(conn)
    [Wurk::Keys::RETRY, Wurk::Keys::DEAD, Wurk::Keys::SCHEDULE].each do |key|
      conn.call('ZRANGE', key, 0, -1).each { |m| conn.call('ZREM', key, m) if m.include?(@queue_name) }
    end
  end

  def enqueue(klass, extra = {})
    payload = { 'class' => klass.name, 'args' => [], 'queue' => @queue_name,
                'jid' => SecureRandom.hex(6), 'created_at' => Time.now.to_f }.merge(extra)
    push_raw(Wurk.dump_json(payload))
    payload
  end

  def push_raw(payload)
    @pool.with { |conn| conn.call('LPUSH', @public_queue, payload) }
    payload
  end

  # Fresh, uniquely-named Worker class whose `perform` runs `body` and can
  # record into a class-level sink. Uniquely named so parallel runs can't
  # collide on constant lookup.
  def worker_that(&body)
    klass = Class.new { include Wurk::Worker }
    klass.instance_variable_set(:@sink, [])
    klass.instance_variable_set(:@body, body)
    klass.define_singleton_method(:sink) { @sink }
    klass.define_singleton_method(:body) { @body }
    klass.define_method(:perform) { |*| self.class.body.call(self.class.sink) }
    Object.const_set("QSL_Worker_#{Process.pid}_#{object_id}_#{SecureRandom.hex(4)}", klass)
    klass
  end
end
