# frozen_string_literal: true

require_relative '../test_helper'

# Drives the Swarm::Restart state machine against fake collaborators — no
# forks, no Redis, injected clock. Covers the
# spawn → await_heartbeat → term_old → await_exit → done sequence plus the
# replacement-death retry, heartbeat timeout, drain-timeout KILL, and abort.
class SwarmRestartTest < Wurk::Test::UnitCase
  parallelize_me!

  SLOT = :slot_token # opaque; Restart only passes it through to spawn

  def setup
    super
    @t = [1000.0]
    @next_pid = [200]
    @children = { 100 => { slot: SLOT, index: 0 } } # the "old" child
    @beating = []
    @spawns = []
    @kills = []
    @backoff = Wurk::Swarm::Backoff.new(base: 1.0, cap: 30.0, reset_after: 60.0, clock: -> { @t[0] })
    @restart = Wurk::Swarm::Restart.new(config)
  end

  def test_idle_when_nothing_queued
    assert_predicate @restart, :idle?
  end

  def test_happy_path_replaces_slot_then_drains_old # rubocop:disable Minitest/MultipleAssertions
    @restart.enqueue([100])

    @restart.advance # spawn replacement

    assert_equal 1, @spawns.size
    assert_empty @kills, 'old must not be TERMed before the replacement heartbeats'

    @beating << @spawns.first[:pid]
    @restart.advance # heartbeat seen → TERM old, enter await_exit

    assert_equal [[100, 'TERM']], @kills

    reap(100)        # old drains and exits
    @restart.advance # await_exit → finish

    assert_predicate @restart, :idle?
  end

  def test_replacement_death_keeps_old_and_retries_after_backoff # rubocop:disable Minitest/MultipleAssertions
    @restart.enqueue([100])
    @restart.advance # spawn first replacement

    reap(@spawns.first[:pid]) # replacement dies before heartbeat
    @restart.advance          # retry_slot: old kept, backoff armed

    assert_empty @kills, 'the surviving old child must never be killed'
    assert_equal 1, @spawns.size, 'no immediate respawn — retry is backed off'

    @restart.advance # backoff not elapsed → still waiting

    assert_equal 1, @spawns.size

    @t[0] += 1.0
    @restart.advance # backoff elapsed → new replacement

    assert_equal 2, @spawns.size
  end

  def test_heartbeat_timeout_proceeds_to_term_old
    @restart.enqueue([100])
    @restart.advance # spawn

    @t[0] += 31      # exceed heartbeat_wait (30) with no heartbeat
    @restart.advance # proceed anyway → TERM old

    assert_equal [[100, 'TERM']], @kills
  end

  def test_overrunning_old_is_killed_after_drain_timeout
    drive_to_await_exit

    @t[0] += 26      # exceed drain_timeout (25)
    @restart.advance # KILL old

    assert_equal [[100, 'TERM'], [100, 'KILL']], @kills

    @restart.advance # must not re-KILL while awaiting the reap

    assert_equal 2, @kills.size

    reap(100)
    @restart.advance

    assert_predicate @restart, :idle?
  end

  def test_claim_exit_ignores_unrelated_pid
    @restart.enqueue([100])
    @restart.advance

    refute @restart.claim_exit(999)
  end

  def test_replacement_death_after_takeover_is_a_normal_crash
    drive_to_await_exit

    # In await_exit the replacement owns the slot; its death is an ordinary
    # crash the swarm respawns, so the machine must not claim it.
    refute @restart.claim_exit(@spawns.first[:pid])
  end

  def test_enqueue_skips_in_flight_slot
    @restart.enqueue([100])
    @restart.advance          # 100 in flight
    @restart.enqueue([100])   # in-flight → ignored

    @beating << @spawns.first[:pid]
    @restart.advance          # TERM old
    reap(100)
    @restart.advance          # finish

    assert_predicate @restart, :idle?
    assert_equal 1, @spawns.size, 'the in-flight slot must not be restarted twice'
  end

  def test_enqueue_collapses_duplicate_pids
    @restart.enqueue([100, 100])
    @restart.advance

    assert_equal 1, @spawns.size
  end

  def test_stale_queue_head_is_dropped
    @restart.enqueue([100])
    @children.delete(100) # old vanished before the restart started

    @restart.advance

    assert_empty @spawns
    assert_predicate @restart, :idle?
  end

  def test_abort_drops_queue_and_in_flight
    @restart.enqueue([100])
    @restart.advance

    refute_predicate @restart, :idle?

    @restart.abort

    assert_predicate @restart, :idle?
  end

  private

  def drive_to_await_exit
    @restart.enqueue([100])
    @restart.advance # spawn
    @beating << @spawns.first[:pid]
    @restart.advance # heartbeat seen → TERM old, await_exit
  end

  def reap(pid)
    @children.delete(pid)
    @restart.claim_exit(pid)
  end

  def config
    Wurk::Swarm::Restart::Config.new(
      spawn: method(:fake_spawn),
      kill: ->(pid, sig) { @kills << [pid, sig] },
      heartbeat: ->(pid) { @beating.include?(pid) },
      describe: ->(pid) { @children[pid] },
      now: -> { @t[0] },
      logger: ::Logger.new(IO::NULL),
      heartbeat_wait: 30,
      drain_timeout: 25,
      backoff: @backoff
    )
  end

  def fake_spawn(slot, idx)
    pid = @next_pid[0]
    @next_pid[0] += 1
    @children[pid] = { slot: slot, index: idx }
    @spawns << { slot: slot, index: idx, pid: pid }
    pid
  end
end
