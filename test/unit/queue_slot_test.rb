# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/heartbeat'

# Wurk::QueueSlot and its Lua script, against real Redis.
#
# The slot model exists to survive the two ways a cap normally breaks: a holder
# that dies without releasing (a counter never comes back down) and a release
# that arrives after its own hold was already reclaimed (a counter frees
# somebody else's slot). Every test below defends one of those, or the
# admission arithmetic they protect.
#
# Distinct tokens stand in for distinct processes: a token is
# `<identity>:<tid>` and the script never reads anything else about a holder,
# so a foreign token here is exactly what another host's fetcher writes. Real
# forks are slice 10's integration test, not this file's job.
#
# Parallel safety: every queue name is namespaced to this test, so its slot key
# is unique to it; the per-worker DB and the teardown FLUSHDB do the rest.
class QueueSlotTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @queue = "cap-#{Process.pid}-#{object_id}"
    @pool = Wurk.configuration.redis_pool
    @pool.with { |conn| Wurk::Lua::Loader.script_load_all(conn) }
  end

  # --- keys and tokens --------------------------------------------------

  def test_key_is_namespaced_under_the_queue_slot_prefix
    assert_equal "queue_slot:#{@queue}", Wurk::QueueSlot.key_for(@queue)
    assert_equal Wurk::Keys.queue_slot(@queue), Wurk::QueueSlot.key_for(@queue)
  end

  # The cap keys off the queue, so two queues must not share a ledger — one
  # busy queue would otherwise hold another's capacity.
  def test_each_queue_holds_its_own_slots
    other = "#{@queue}-other"

    assert Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'a')
    assert Wurk::QueueSlot.acquire(other, capacity: 1, token: 'b')
    assert_equal 1, Wurk::QueueSlot.in_use(@queue)
    assert_equal 1, Wurk::QueueSlot.in_use(other)
  ensure
    @pool.with { |conn| conn.call('DEL', Wurk::QueueSlot.key_for("#{@queue}-other")) }
  end

  def test_token_names_this_process_and_thread
    assert_equal "#{Wurk::Component.identity}:#{Wurk::Component.tid}", Wurk::QueueSlot.token
  end

  def test_token_is_stable_within_a_thread_and_distinct_across_them
    mine = Wurk::QueueSlot.token

    assert_same mine, Wurk::QueueSlot.token
    refute_equal mine, Thread.new { Wurk::QueueSlot.token }.value
  end

  # The half a deferred release needs. Two claims on one thread have to be two
  # members, or the release of the first takes the second's capacity with it.
  def test_a_claim_token_is_this_thread_plus_a_claim_of_its_own
    first = Wurk::QueueSlot.claim_token
    second = Wurk::QueueSlot.claim_token

    assert_match(/\A#{Regexp.escape(Wurk::QueueSlot.token)}:\d+\z/, first)
    refute_equal first, second
    refute_equal second, Thread.new { Wurk::QueueSlot.claim_token }.value
  end

  # A hold is refreshed on the beat, so it has to outlive a missed beat by
  # exactly as long as the holder's own `processes` entry does. Pinned rather
  # than aliased: queue_slot.rb deliberately does not require the heartbeat
  # (and its Processor dependency) for one integer.
  def test_hold_ttl_matches_the_heartbeat_ttl
    assert_equal Wurk::Heartbeat::TTL_SECONDS, Wurk::QueueSlot::TTL_SECONDS
  end

  # --- admission --------------------------------------------------------

  def test_admits_up_to_capacity_and_refuses_the_extra
    admitted = 3.times.map { |i| Wurk::QueueSlot.acquire(@queue, capacity: 2, token: "holder-#{i}") }

    assert_equal [true, true, false], admitted
    assert_equal 2, Wurk::QueueSlot.in_use(@queue)
  end

  def test_a_released_slot_admits_the_waiter
    2.times { |i| Wurk::QueueSlot.acquire(@queue, capacity: 2, token: "holder-#{i}") }

    refute Wurk::QueueSlot.acquire(@queue, capacity: 2, token: 'waiter')
    assert Wurk::QueueSlot.release(@queue, token: 'holder-0')
    assert Wurk::QueueSlot.acquire(@queue, capacity: 2, token: 'waiter')
  end

  def test_a_refused_acquire_holds_nothing
    Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'winner')

    refute Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'loser')
    assert_equal ['winner'], members
  end

  def test_capacity_is_read_from_the_caller_not_from_redis
    assert Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'a')
    # The rolling-deploy case: a process running the newer, larger cap keeps
    # fetching while one running the old cap does not.
    refute Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'b')
    assert Wurk::QueueSlot.acquire(@queue, capacity: 5, token: 'b')
  end

  def test_a_lowered_cap_admits_nothing_until_the_queue_drains
    3.times { |i| Wurk::QueueSlot.acquire(@queue, capacity: 3, token: "holder-#{i}") }

    refute Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'waiter')
    2.times { |i| Wurk::QueueSlot.release(@queue, token: "holder-#{i}") }

    refute Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'waiter')
    Wurk::QueueSlot.release(@queue, token: 'holder-2')

    assert Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'waiter')
  end

  def test_capacity_must_be_positive
    assert_raises(ArgumentError) { Wurk::QueueSlot.acquire(@queue, capacity: 0, token: 'a') }
    assert_raises(ArgumentError) { Wurk::QueueSlot.acquire(@queue, capacity: -1, token: 'a') }
    assert_raises(ArgumentError) { Wurk::QueueSlot.acquire(@queue, capacity: 'many', token: 'a') }
    assert_empty members
  end

  def test_ttl_must_be_positive
    assert_raises(ArgumentError) { Wurk::QueueSlot.acquire(@queue, capacity: 1, ttl: 0, token: 'a') }
    assert_empty members
  end

  # --- replay -----------------------------------------------------------

  # The acquire runs on the pool's idempotent path, so a lost reply is retried.
  # A retry that reported a refusal would leave a slot held by a caller that
  # believes it holds nothing — nothing would release it before the TTL.
  def test_a_replayed_acquire_at_capacity_still_reports_the_hold
    assert Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'a')
    assert Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'a'), 'a holder must not be refused its own slot'
  end

  def test_a_replayed_acquire_does_not_count_twice
    3.times { Wurk::QueueSlot.acquire(@queue, capacity: 2, token: 'a') }

    assert_equal 1, Wurk::QueueSlot.in_use(@queue)
    assert Wurk::QueueSlot.acquire(@queue, capacity: 2, token: 'b'), 'the second slot was never taken'
  end

  def test_a_replayed_acquire_extends_the_hold
    Wurk::QueueSlot.acquire(@queue, capacity: 1, ttl: 5, token: 'a')
    first = score('a')
    Wurk::QueueSlot.acquire(@queue, capacity: 1, ttl: 3600, token: 'a')

    assert_operator score('a'), :>, first
  end

  # --- crash safety -----------------------------------------------------

  # A SIGKILLed holder is exactly a member whose expiry has passed and whom
  # nobody is refreshing. Written directly rather than slept for: the point is
  # the reclaim, not the wall clock, and a real kill is the integration test.
  def test_an_expired_holder_is_reclaimed_without_operator_action
    Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'killed')
    expire('killed')

    assert Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'fresh'), 'capacity never came back'
    assert_equal ['fresh'], members, 'the dead holder was left behind'
  end

  def test_a_hold_that_is_still_live_is_not_reclaimed
    Wurk::QueueSlot.acquire(@queue, capacity: 1, ttl: 3600, token: 'running')

    refute Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'other')
    assert_equal ['running'], members
  end

  # The mirror of the leak, and the reason this is not a counter: a release
  # whose hold already expired must free nothing, because the capacity it used
  # to name now belongs to somebody else.
  def test_releasing_an_expired_hold_frees_nobody_elses_slot
    Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'slow')
    expire('slow')
    Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'successor')

    refute Wurk::QueueSlot.release(@queue, token: 'slow'), 'the expired hold was reported as live'
    refute Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'gatecrasher')
    assert_equal ['successor'], members
  end

  def test_releasing_a_slot_never_held_removes_nothing
    Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'holder')

    refute Wurk::QueueSlot.release(@queue, token: 'stranger')
    assert_equal ['holder'], members
  end

  def test_releasing_twice_frees_one_slot
    2.times { |i| Wurk::QueueSlot.acquire(@queue, capacity: 2, token: "holder-#{i}") }

    assert Wurk::QueueSlot.release(@queue, token: 'holder-0')
    refute Wurk::QueueSlot.release(@queue, token: 'holder-0')
    assert Wurk::QueueSlot.acquire(@queue, capacity: 2, token: 'waiter')
    refute Wurk::QueueSlot.acquire(@queue, capacity: 2, token: 'gatecrasher')
  end

  # --- leaks ------------------------------------------------------------

  # Redis drops a ZSET with its last member, which is why the key carries no
  # TTL of its own: a drained queue leaves nothing behind to expire.
  def test_the_slot_key_disappears_when_the_last_holder_releases
    2.times { |i| Wurk::QueueSlot.acquire(@queue, capacity: 2, token: "holder-#{i}") }
    2.times { |i| Wurk::QueueSlot.release(@queue, token: "holder-#{i}") }

    assert_equal 0, slot_key_exists
  end

  def test_churning_through_a_capped_queue_leaves_no_slots_behind
    200.times do |i|
      assert Wurk::QueueSlot.acquire(@queue, capacity: 2, token: "holder-#{i % 2}")
      Wurk::QueueSlot.release(@queue, token: "holder-#{i % 2}")
    end

    assert_equal 0, Wurk::QueueSlot.in_use(@queue)
    assert_equal 0, slot_key_exists
  end

  # --- reads ------------------------------------------------------------

  def test_in_use_is_zero_for_a_queue_nobody_is_running
    assert_equal 0, Wurk::QueueSlot.in_use(@queue)
  end

  # A killed holder stops being reported when its hold expires, not when the
  # next acquire happens to sweep it — the dashboard reads this between fetches.
  def test_in_use_ignores_expired_holders
    2.times { |i| Wurk::QueueSlot.acquire(@queue, capacity: 2, token: "holder-#{i}") }
    expire('holder-0')

    assert_equal 1, Wurk::QueueSlot.in_use(@queue)
    assert_equal 2, members.size, 'the expired holder is still on the ZSET until the next acquire sweeps it'
  end

  # --- pools ------------------------------------------------------------

  def test_an_explicit_pool_is_used_instead_of_the_default
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, timeout: 2, name: 'queue-slot-pool')

    assert Wurk::QueueSlot.acquire(@queue, capacity: 1, token: 'a', pool: pool)
    assert_equal 1, Wurk::QueueSlot.in_use(@queue, pool: pool)
    assert_equal ['a'], members
  ensure
    pool&.disconnect!
  end

  private

  def members
    @pool.with { |conn| conn.call('ZRANGE', Wurk::QueueSlot.key_for(@queue), 0, -1) }
  end

  def slot_key_exists
    @pool.with { |conn| conn.call('EXISTS', Wurk::QueueSlot.key_for(@queue)) }
  end

  def score(token)
    @pool.with { |conn| conn.call('ZSCORE', Wurk::QueueSlot.key_for(@queue), token) }.to_f
  end

  # Backdate a hold to the moment before now, which is the state a holder that
  # stopped refreshing reaches on its own.
  def expire(token)
    @pool.with { |conn| conn.call('ZADD', Wurk::QueueSlot.key_for(@queue), Time.now.to_f - 1, token) }
  end
end
