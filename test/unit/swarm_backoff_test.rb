# frozen_string_literal: true

require_relative '../test_helper'

# Pure per-slot exponential backoff (Swarm::Backoff). Deterministic — the clock
# is injected, so no sleeping and no forks.
class SwarmBackoffTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @t = [1000.0]
    @backoff = Wurk::Swarm::Backoff.new(base: 1.0, cap: 30.0, reset_after: 60.0, clock: -> { @t[0] })
  end

  def test_unknown_key_is_ready_and_not_pending
    assert @backoff.ready?(0)
    refute @backoff.pending?(0)
  end

  def test_first_failure_uses_base_delay_and_is_pending
    assert_in_delta 1.0, @backoff.fail(0)
    assert @backoff.pending?(0)
    refute @backoff.ready?(0)
  end

  def test_becomes_ready_once_delay_elapses
    @backoff.fail(0)
    @t[0] += 1.0

    assert @backoff.ready?(0)
  end

  def test_rapid_failures_double_until_capped # rubocop:disable Minitest/MultipleAssertions
    assert_in_delta 1.0, @backoff.fail(0)
    assert_in_delta 2.0, @backoff.fail(0)
    assert_in_delta 4.0, @backoff.fail(0)
    assert_in_delta 8.0, @backoff.fail(0)
    assert_in_delta 16.0, @backoff.fail(0)
    assert_in_delta 30.0, @backoff.fail(0) # 32 clamped to cap
    assert_in_delta 30.0, @backoff.fail(0)
  end

  def test_survival_past_reset_window_restarts_streak
    3.times { @backoff.fail(0) }

    assert_in_delta 1.0, @backoff.fail(0, lifetime: 60.0)
  end

  def test_short_lifetime_keeps_escalating
    @backoff.fail(0)

    assert_in_delta 2.0, @backoff.fail(0, lifetime: 59.9)
  end

  def test_consume_clears_pending_but_preserves_streak
    @backoff.fail(0)
    @backoff.consume(0)

    refute @backoff.pending?(0)
    assert_in_delta 2.0, @backoff.fail(0)
  end

  def test_clear_forgets_streak_and_schedule
    2.times { @backoff.fail(0) }
    @backoff.clear(0)

    refute @backoff.pending?(0)
    assert_in_delta 1.0, @backoff.fail(0)
  end

  def test_keys_track_independently
    @backoff.fail(0)
    @backoff.fail(0)

    assert_in_delta 1.0, @backoff.fail(1)
  end
end
