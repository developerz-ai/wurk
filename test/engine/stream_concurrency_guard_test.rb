# frozen_string_literal: true

require_relative '../engine_test_helper'

# Pins the self-healing half of the SSE concurrency cap (#101). A stream whose
# thread is killed mid-flight never runs the `ensure` in #with_stream_slot, so
# the guard has to reclaim the slot on its own — otherwise MAX_CONCURRENT_STREAMS
# such deaths 503 `/api/stream` for the rest of the process's life.
class StreamConcurrencyGuardTest < Wurk::Test::EngineCase
  parallelize_me!

  GUARD = ::Wurk::StreamConcurrencyGuard
  CAP = GUARD::MAX_CONCURRENT_STREAMS

  # Slots are thread-scoped, so this drops everything this test thread holds
  # however the test exited; slots held by dead threads clean themselves up.
  def teardown
    CAP.times { GUARD.release }
  ensure
    super
  end

  def test_dead_holder_frees_its_slot
    fill_cap_with_dead_holders

    assert GUARD.acquire, 'a slot whose holder died must be reclaimed'
  end

  def test_every_dead_holder_is_reclaimed_not_just_one
    fill_cap_with_dead_holders

    assert_equal CAP, CAP.times.count { GUARD.acquire }, 'all leaked slots must come back'
    refute GUARD.acquire, 'the cap must still hold once the reclaimed slots are taken'
  end

  # The cap only self-heals for holders that are gone; a live stream keeps its
  # slot, which is the whole point of the bound.
  def test_live_holders_keep_their_slots
    gate = Queue.new
    ready = Queue.new
    threads = Array.new(CAP) do
      Thread.new do
        ready << GUARD.acquire
        gate.pop
      end
    end

    CAP.times { assert ready.pop, 'each parked thread should get a slot' }

    refute GUARD.acquire, 'live holders must still count against the cap'
  ensure
    CAP.times { gate << :go }
    threads&.each(&:join)
  end

  # Acquire/release bracket one block on one thread; a release from anywhere
  # else must not take a slot away from the thread that is streaming.
  def test_release_from_another_thread_leaves_the_slot_with_its_owner
    assert GUARD.acquire
    Thread.new { GUARD.release }.join

    assert_equal(CAP - 1, (CAP - 1).times.count { GUARD.acquire })
    refute GUARD.acquire, 'a foreign release must not free the slot its owner still holds'
  end

  def test_release_without_a_slot_does_not_widen_the_cap
    3.times { GUARD.release }

    assert_equal(CAP, CAP.times.count { GUARD.acquire })
    refute GUARD.acquire, 'stray releases must not hand out extra capacity'
  end

  # The user-visible fix: every slot leaked by a hard-reaped thread, yet the
  # next request still streams instead of 503ing forever.
  def test_stream_still_serves_after_every_slot_leaked
    fill_cap_with_dead_holders

    get '/wurk/api/stream?max_duration=0&tick=0'

    assert_equal 200, last_response.status, "non-200: #{last_response.body[0, 300]}"
    assert_includes last_response.body, 'event: stats'
  end

  private

  # Reproduces the leak: each thread takes a slot and dies without releasing.
  def fill_cap_with_dead_holders
    threads = Array.new(CAP) { Thread.new { GUARD.acquire } }
    threads.each(&:join)

    assert threads.all? { |thread| thread.value == true }, 'setup should have filled every slot'
  end
end
