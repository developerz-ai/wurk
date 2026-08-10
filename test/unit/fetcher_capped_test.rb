# frozen_string_literal: true

require_relative '../test_helper'

# Fetching under a global per-queue concurrency cap: Wurk::Fetcher::Capped and
# lib/wurk/lua/fetch_slot.lua, against real Redis.
#
# The slot ledger itself is QueueSlotTest's subject. This file is about the
# three promises the fetch path makes on top of it: an install that caps
# nothing fetches exactly as it did before, a capped queue costs no round trip
# more than an uncapped one, and a queue at capacity backs off without taking
# the rest of the pass down with it.
#
# Distinct tokens stand in for other hosts — a token is opaque to the script,
# so a foreign one here is what another worker's fetcher writes. Real forks are
# the slice's integration test, not this file's job. This process's own members
# are `<identity>:<tid>:<claim>` (QueueSlot.claim_token), which is why the
# assertions read the token off the unit of work rather than rebuilding it.
#
# Parallel safety: every queue name is namespaced to this test, so its public
# queue, private list and slot key are unique to it.
class FetcherCappedTest < Wurk::Test::UnitCase
  parallelize_me!

  # Counts pool checkouts alongside commands: the headline claim of this slice
  # is about *round trips*, and a gate that spent an extra one while keeping the
  # command count flat would read as free here without it.
  class TripCountingSpy < Wurk::Test::CommandSpy
    attr_reader :trips

    def initialize(pool)
      super
      @trips = 0
    end

    def with(&)
      @trips += 1
      super
    end
  end

  def setup
    super
    @queue_name   = "fc-#{Process.pid}:#{object_id}"
    @public_queue = "#{Wurk::Keys::QUEUE_PREFIX}#{@queue_name}"
    @open_name    = "#{@queue_name}-open"
    @open_queue   = "#{Wurk::Keys::QUEUE_PREFIX}#{@open_name}"
    @config       = Wurk::Configuration.new
  end

  def teardown
    # Left behind, this test's holds would have every later beat in this worker
    # refreshing a slot key that no longer exists.
    drop_local_holds(Wurk::Keys.queue_slot(@queue_name))
    @pool&.with do |conn|
      conn.call('DEL', @public_queue, @open_queue, private_queue(@public_queue),
                private_queue(@open_queue), Wurk::Keys.queue_slot(@queue_name))
    end
  ensure
    super
  end

  # --- the unconfigured path ------------------------------------------

  # The gate on the whole slice. An install that caps nothing has to fetch with
  # the commands it fetched with before — not those commands plus a question.
  def test_an_uncapped_capsule_fetches_in_one_command_and_takes_no_slot
    build_fetcher(caps: {})
    enqueue(@public_queue, 'p1')
    prime_paused_cache!
    spy = install_command_spy

    assert_equal 'p1', @fetcher.retrieve_work.job
    assert_equal 1, spy.count, 'an uncapped fetch is one LMOVE, as it was before the gate existed'
    assert_equal 0, slot_count
  end

  # An uncapped queue inside a capsule that caps a *different* one still goes
  # through the plain LMOVE: the gate is per queue, not per capsule.
  def test_an_uncapped_queue_in_a_capped_capsule_is_still_a_plain_lmove
    build_fetcher(queues: [@open_name, @queue_name])
    enqueue(@open_queue, 'open-1')
    prime_paused_cache!
    spy = install_command_spy
    uow = @fetcher.retrieve_work

    assert_equal @open_queue, uow.queue
    assert_equal 1, spy.count
    assert_equal 0, slot_count
  end

  # --- admission ------------------------------------------------------

  def test_a_capped_fetch_claims_one_slot_named_for_this_claim
    build_fetcher
    enqueue(@public_queue, 'p1')
    uow = @fetcher.retrieve_work

    assert_equal 'p1', uow.job
    assert_equal [uow.slot_token], slot_members
    assert_match(/\A#{Regexp.escape(Wurk::QueueSlot.token)}:\d+\z/, uow.slot_token,
                 'the member names this thread and the claim it made')
  end

  # The refusal has to happen before either list is touched, or a worker that
  # cannot run the job has still taken it off the queue.
  def test_a_queue_at_capacity_yields_nothing_and_leaves_the_job_queued
    build_fetcher
    hold_slot('another-host:1')
    enqueue(@public_queue, 'p1')

    assert_nil @fetcher.retrieve_work
    assert_equal 1, llen(@public_queue)
    assert_equal 0, llen(private_queue(@public_queue))
  end

  def test_capacity_freed_elsewhere_is_claimed_on_the_next_pass
    build_fetcher
    hold_slot('another-host:1')
    enqueue(@public_queue, 'p1')

    assert_nil @fetcher.retrieve_work

    Wurk::QueueSlot.release(@queue_name, token: 'another-host:1', pool: @pool)
    clear_backoff!

    assert_equal 'p1', @fetcher.retrieve_work.job
  end

  # An empty queue must not spend capacity the rest of the cluster could use:
  # the script only takes a slot once the job is already in the private list.
  def test_an_empty_capped_queue_takes_no_slot
    build_fetcher

    assert_nil @fetcher.retrieve_work
    assert_equal 0, slot_count
  end

  # ...and must not hand back a hold that is still doing its job either. The
  # holder here is this very thread, whose previous job has not been released.
  def test_an_empty_capped_queue_leaves_a_live_hold_alone
    build_fetcher
    enqueue(@public_queue, 'p1')
    uow = @fetcher.retrieve_work

    assert_nil @fetcher.retrieve_work
    assert_equal [uow.slot_token], slot_members
  end

  # Crash safety, on the fetch path: a holder that stopped refreshing — killed,
  # hung, gone in a way that never reached its release — must not hold capacity
  # past its expiry. No operator action, and no sweeper either; the claim itself
  # reclaims it.
  def test_a_holder_that_stopped_refreshing_does_not_keep_the_queue_full
    build_fetcher
    expire_slot('killed-host:1')
    enqueue(@public_queue, 'p1')
    uow = @fetcher.retrieve_work

    assert_equal 'p1', uow.job
    assert_equal [uow.slot_token], slot_members
  end

  # The script's replay arm. A claim whose reply was lost is retried on the
  # pool's idempotent path — with the same token, built before the retried block
  # — and has to converge on "you hold it" rather than be refused against its
  # own member, or the slot is held by a caller that believes it owns nothing
  # and nobody releases it before the TTL.
  def test_a_replayed_claim_converges_on_the_member_it_already_holds
    build_fetcher
    enqueue(@public_queue, 'p1')
    enqueue(@public_queue, 'p2')
    token = @fetcher.retrieve_work.slot_token

    assert_equal 'p2', replay_claim(token).last
    assert_equal [token], slot_members, 'a claim must never count itself twice'
  end

  # And only its own. A token names one claim, so the thread's *next* claim is a
  # different member and is refused like anybody else while the queue is full —
  # the ledger says the cap's worth of capacity is spoken for, and it is right
  # until the finished job's release lands.
  def test_a_second_claim_by_the_same_thread_is_refused_at_capacity
    build_fetcher
    enqueue(@public_queue, 'p1')
    held = @fetcher.retrieve_work.slot_token

    assert_nil @fetcher.retrieve_work
    assert_equal [held], slot_members
  end

  # --- round trips ----------------------------------------------------

  # The reason the gate is a script and not an acquire around the fetch:
  # bracketing measured 2.2x-2.6x the uncapped cost. One checkout, one pipeline.
  def test_the_held_ack_rides_the_gated_fetch_in_one_round_trip
    build_fetcher
    enqueue(@public_queue, 'p1')
    @fetcher.retrieve_work.acknowledge
    enqueue(@public_queue, 'p2')
    spy = install_trip_spy

    assert_equal 'p2', @fetcher.retrieve_work.job
    assert_equal 1, spy.trips, 'the gate must join the fetch pipeline, not take a round trip of its own'
    assert_equal 3, spy.count,
                 'the pipeline is the held LREM, its slot release and the gated fetch, nothing else'
    assert_equal ['p2'], lrange(private_queue(@public_queue)), 'the piggybacked ACK still retired p1'
  end

  def test_a_gated_fetch_without_a_held_ack_is_a_single_command
    build_fetcher
    enqueue(@public_queue, 'p1')
    prime_paused_cache!
    spy = install_trip_spy

    refute_nil @fetcher.retrieve_work
    assert_equal 1, spy.trips
    assert_equal 1, spy.count
  end

  # NOSCRIPT recovery for the pipelined arm: a pipelined EVALSHA surfaces
  # NOSCRIPT only at finalize, so Lua::Loader.pipelined_eval reloads and replays
  # through source-embedded EVAL. The replayed ACK is a no-op, the fetch lands.
  def test_a_flushed_script_cache_is_reloaded_and_the_gated_fetch_still_lands
    build_fetcher
    enqueue(@public_queue, 'p1')
    @fetcher.retrieve_work.acknowledge
    enqueue(@public_queue, 'p2')
    @pool.with { |conn| conn.call('SCRIPT', 'FLUSH') }

    assert_equal 'p2', @fetcher.retrieve_work.job
    assert_equal ['p2'], lrange(private_queue(@public_queue))
  ensure
    # The EVALSHA cache is SERVER-wide, not per-DB, so this flush is visible to
    # every parallel_fork worker. Reload the moment the assertion below is done
    # so the window a sibling suite can be caught in is a handful of commands
    # rather than the rest of this test. (ClientBatchPipelineTest, which counts
    # pipelines, detects the interference and skips rather than failing.)
    @pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }
  end

  # A claim that never reached Redis must hand its ACK back, or the finished job
  # it belonged to is left in the private list for the next boot to run again.
  def test_a_failed_claim_returns_the_ack_it_was_carrying
    build_fetcher
    seed_private(private_queue(@public_queue), 'done')
    # So the pass reaches the claim at all: an unprimed paused cache raises
    # first, and the ACK would never have left its slot.
    prime_paused_cache!
    @fetcher.send(:defer_ack, uow_for(@public_queue, 'done'))

    with_dead_redis { assert_raises(DeadRedis) { @fetcher.retrieve_work } }

    @fetcher.flush_pending_acks

    assert_equal 0, llen(private_queue(@public_queue))
  end

  # The same window with nothing held: the failure still propagates, and the
  # fetcher does not invent an ACK to hand back.
  def test_a_failed_claim_carrying_no_ack_hands_nothing_back
    build_fetcher
    prime_paused_cache!

    with_dead_redis { assert_raises(DeadRedis) { @fetcher.retrieve_work } }

    spy = install_command_spy
    @fetcher.flush_pending_acks

    assert_equal 0, spy.count, 'nothing was held, so nothing must be sent'
  end

  # --- fairness -------------------------------------------------------

  # The hard part of the slice: a queue at capacity backs off without taking the
  # rest of the pass with it. Strict order puts the capped queue first.
  def test_a_capped_queue_at_capacity_does_not_stall_the_queues_behind_it
    build_fetcher(queues: [@queue_name, @open_name])
    hold_slot('another-host:1')
    enqueue(@public_queue, 'capped-1')
    enqueue(@open_queue, 'open-1')
    uow = @fetcher.retrieve_work

    assert_equal @open_queue, uow.queue
    assert_equal 'open-1', uow.job
  end

  # A `no` cannot change faster than a job finishes somewhere in the cluster, so
  # re-asking every pass is how a full queue turns into a spin.
  def test_a_refusal_is_remembered_so_a_full_queue_is_not_re_asked_every_pass
    build_fetcher
    hold_slot('another-host:1')
    enqueue(@public_queue, 'p1')
    @fetcher.retrieve_work
    spy = install_command_spy

    assert_nil @fetcher.retrieve_work
    assert_equal 0, spy.count, 'a queue known to be at capacity must be skipped locally'
  end

  # And the skip has to be local *and* free: the pass carries on to the queues
  # behind it without having spent anything on the one it stepped over.
  def test_a_skipped_queue_costs_nothing_and_the_pass_still_serves_the_rest
    build_fetcher(queues: [@queue_name, @open_name])
    hold_slot('another-host:1')
    @fetcher.retrieve_work
    enqueue(@open_queue, 'open-1')
    spy = install_command_spy

    assert_equal 'open-1', @fetcher.retrieve_work.job
    assert_equal 1, spy.count, 'the skipped queue adds nothing to the LMOVE the open one costs'
  end

  # A pass that skipped every capped queue never handed its ACK to anything, and
  # the sleep it ends in cannot carry one either.
  def test_a_pass_that_skips_every_capped_queue_still_flushes_its_ack
    build_fetcher(poll: 0.05)
    hold_slot('another-host:1')
    @fetcher.retrieve_work
    seed_private(private_queue(@public_queue), 'done')
    @fetcher.send(:defer_ack, uow_for(@public_queue, 'done'))

    assert_nil @fetcher.retrieve_work
    assert_equal 0, llen(private_queue(@public_queue))
  end

  # --- the blocking fall-through --------------------------------------

  # BLMOVE has no gated form, so a capped queue is never the one we park on.
  def test_the_blocking_fallback_parks_on_the_first_uncapped_queue
    build_fetcher(queues: [@queue_name, @open_name])
    args = captured_blmove_args
    @fetcher.retrieve_work

    assert_equal @open_queue, args[2]
  end

  def test_an_idle_capsule_still_blocks_for_a_full_poll_interval
    build_fetcher(queues: [@queue_name, @open_name], poll: 1.5)
    args = captured_blmove_args
    @fetcher.retrieve_work

    assert_in_delta 1.5, args[0]
  end

  # Freed capacity should be picked up in a backoff, not a poll interval — so
  # while a gate is closed the block is shortened to that gate's own re-check.
  def test_a_closed_gate_shortens_the_block_to_its_own_recheck
    build_fetcher(queues: [@queue_name, @open_name], poll: 1.5)
    hold_slot('another-host:1')
    enqueue(@public_queue, 'p1')
    args = captured_blmove_args
    @fetcher.retrieve_work

    assert_in_delta Wurk::Fetcher::Capped::CAPPED_BACKOFF, args[0]
  end

  # With every fetchable queue capped there is nothing to block on at all, so
  # the pass idles the wall clock a timed-out block would have spent.
  def test_with_every_queue_capped_the_pass_sleeps_instead_of_blocking
    build_fetcher(poll: 0.1)
    blocked = false
    @capsule.define_singleton_method(:fetch_redis) { |**_opts, &_blk| blocked = true }

    assert_operator elapsed { assert_nil @fetcher.retrieve_work }, :>=, 0.1
    refute blocked, 'a capped queue must never be the one we park a BLMOVE on'
  end

  # --- the gate itself ------------------------------------------------

  def test_a_gate_closes_for_the_backoff_and_then_reopens
    gate = Wurk::Fetcher::Capped::Gate.new(1, 'queue_slot:x', 0.0)

    refute gate.blocked?(100.0)
    gate.block!(100.0)

    assert gate.blocked?(100.0 + (Wurk::Fetcher::Capped::CAPPED_BACKOFF / 2))
    refute gate.blocked?(100.0 + Wurk::Fetcher::Capped::CAPPED_BACKOFF)
  end

  def test_only_the_named_queues_resolve_a_gate
    build_fetcher(queues: [@queue_name, @open_name])

    refute_nil @fetcher.send(:gate_for, @public_queue)
    assert_nil @fetcher.send(:gate_for, @open_queue)
  end

  def test_a_gate_carries_the_configured_capacity_and_its_slot_key
    build_fetcher(caps: { @queue_name => 7 })
    gate = @fetcher.send(:gate_for, @public_queue)

    assert_equal 7, gate.capacity
    assert_equal Wurk::Keys.queue_slot(@queue_name), gate.slot_key
  end

  private

  # Raised by #with_dead_redis in place of a real connection error, so a test
  # asserting the failure path can't accidentally pass on some other raise.
  class DeadRedis < StandardError; end

  # The capsule under test. Caps default to "this test's queue, ceiling of one",
  # which is the smallest cap that can be at capacity.
  def build_fetcher(caps: { @queue_name => 1 }, queues: [@queue_name], poll: 0.05)
    @config.global_concurrency = caps
    @config[:fetch_poll_interval] = poll
    @capsule = Wurk::Capsule.new('test', @config)
    @capsule.queues = queues
    @pool = @capsule.redis_pool
    @pool.with { |conn| Wurk::Lua::Loader.script_load_all(conn) }
    @fetcher = Wurk::Fetcher::Reliable.new(@capsule)
  end

  # Stand in for a holder on another host.
  def hold_slot(token)
    Wurk::QueueSlot.acquire(@queue_name, capacity: 99, token: token, pool: @pool)
  end

  # What the pool's idempotent retry sends when a claim's reply was lost: the
  # same script with the same token, a second time.
  def replay_claim(token)
    keys = [Wurk::Keys.queue_slot(@queue_name), @public_queue, private_queue(@public_queue)]
    @pool.with do |conn|
      Wurk::Lua::Loader.eval_cached(conn, :fetch_slot, keys: keys,
                                                       argv: [1, token, Wurk::QueueSlot::TTL_SECONDS])
    end
  end

  # This test's holds, off the process-wide ledger. Nothing here runs a
  # Processor, so no ACK ever carries the release that would take them off, and
  # a member named for a claim cannot be rebuilt from the outside.
  def drop_local_holds(slot_key)
    Wurk::QueueSlot::HELD.snapshot.each { |token, key| Wurk::QueueSlot::HELD.drop(token, key) if key == slot_key }
  end

  # A hold whose expiry is already behind Redis's own clock: what a SIGKILLed
  # holder leaves once its last refresh ages out.
  def expire_slot(token)
    @pool.with { |conn| conn.call('ZADD', Wurk::Keys.queue_slot(@queue_name), Time.now.to_i - 1, token) }
  end

  # Reopen a gate the fetcher closed, without waiting out its backoff.
  def clear_backoff!
    @fetcher.send(:gate_for, @public_queue).blocked_until = 0.0
  end

  def slot_members
    @pool.with { |conn| conn.call('ZRANGE', Wurk::Keys.queue_slot(@queue_name), 0, -1) }
  end

  def slot_count = slot_members.size

  # Every fetch pass consults the `paused` SET, cached per PAUSED_TTL. Reading
  # it once before a spy is installed keeps that shared cost out of counts that
  # are about the fetch itself.
  def prime_paused_cache!
    @fetcher.queues_cmd
  end

  def install_command_spy
    install_spy(Wurk::Test::CommandSpy.new(@pool))
  end

  def install_trip_spy
    install_spy(TripCountingSpy.new(@pool))
  end

  # Points the capsule's main pool at a counting stand-in. PoolCheckout falls
  # through to `pool.with` for anything that isn't a RedisPool, so the fetcher's
  # `idempotent: true` claims resolve here unchanged.
  def install_spy(spy)
    @capsule.define_singleton_method(:redis_pool) { spy }
    spy
  end

  # Stub the capsule's fetch pool so the BLMOVE's arguments can be captured
  # without actually blocking on a real empty queue.
  def captured_blmove_args
    box = []
    conn = Object.new
    conn.define_singleton_method(:blocking_call) do |*a|
      box.replace(a)
      nil
    end
    @capsule.define_singleton_method(:fetch_redis) { |**_opts, &blk| blk.call(conn) }
    box
  end

  def with_dead_redis
    @capsule.define_singleton_method(:redis) { |**_opts, &_blk| raise DeadRedis }
    yield
  ensure
    @capsule.singleton_class.remove_method(:redis)
  end

  def elapsed
    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    yield
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started
  end

  def private_queue(public_q) = Wurk::Fetcher::Reliable.private_queue_name(public_q)

  def enqueue(public_q, payload)
    @pool.with { |conn| conn.call('LPUSH', public_q, payload) }
    payload
  end

  def seed_private(key, *payloads)
    @pool.with { |conn| conn.call('RPUSH', key, *payloads) }
  end

  def llen(key) = @pool.with { |conn| conn.call('LLEN', key) }

  def lrange(key) = @pool.with { |conn| conn.call('LRANGE', key, 0, -1) }

  def uow_for(public_q, payload)
    Wurk::Fetcher::Reliable::UnitOfWork.new(queue: public_q, private_queue: private_queue(public_q),
                                            job: payload, config: @capsule, fetcher: @fetcher)
  end
end
