# frozen_string_literal: true

require_relative '../test_helper'

# Both batch index ZSETs are append-only from every automatic path: `batches`
# gains a member on first flush, `dead-batches` on `:death`, and only the manual
# `Status#delete` / death-recovery ZREMs ever remove one. A batch left to expire
# leaves its index entry behind forever, so both sets are now trimmed on write —
# same two axes as the morgue (`DeadSet#trim`). Spec: sidekiq-pro.md §2.8.
#
# Parallel safety: the trims that run through the real write paths use the
# default window, which only evicts members older than the 30d batch expiry —
# nothing but this file creates those. The rank axis runs on a PID-scoped key via
# the `max:` override instead of mutating the process-global configuration.
class BatchIndexTrimTest < Wurk::Test::UnitCase
  parallelize_me!

  WINDOW = Wurk::Batch::DEFAULT_EXPIRY_SECONDS

  def setup
    super
    @pool  = Wurk.configuration.redis_pool
    @ns    = "#{Process.pid}-#{object_id}"
    @queue = "bix-#{@ns}"
    @key   = "bix-index-#{@ns}"
    @now   = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
  end

  # --- `batches`, trimmed by the first-flush pipeline ---------------------

  def test_first_flush_indexes_the_batch
    bid = flush_batch

    assert_includes members('batches'), bid
  end

  def test_first_flush_trims_stale_members_from_batches
    seed('batches', "stale-#{@ns}" => @now - WINDOW - 60)
    flush_batch

    refute_includes members('batches'), "stale-#{@ns}"
  end

  def test_first_flush_leaves_members_inside_the_window_alone
    seed('batches', "fresh-#{@ns}" => @now - 60)
    flush_batch

    assert_includes members('batches'), "fresh-#{@ns}"
  end

  # --- `dead-batches`, trimmed by Callbacks#index_dead --------------------

  def test_fire_death_indexes_the_batch
    bid = "bix-dead-#{@ns}"
    Wurk::Batch::Callbacks.fire_death(bid)

    assert_includes members('dead-batches'), bid
  end

  def test_fire_death_trims_stale_members_from_dead_batches
    seed('dead-batches', "stale-#{@ns}" => @now - WINDOW - 60)
    Wurk::Batch::Callbacks.fire_death("bix-dead-#{@ns}")

    refute_includes members('dead-batches'), "stale-#{@ns}"
  end

  # --- the primitive ------------------------------------------------------

  # Default window is the batch hash TTL: past it `b-<bid>` is gone and the
  # index entry only resolves to an empty Status.
  def test_trim_index_defaults_to_the_batch_expiry_window
    seed(@key, 'expired' => @now - WINDOW - 60, 'live' => @now - WINDOW + 3600)
    trim(@key)

    assert_equal %w[live], members(@key)
  end

  def test_trim_index_drops_members_older_than_an_overridden_timeout
    seed(@key, 'old' => @now - 120, 'new' => @now - 10)
    trim(@key, timeout: 60)

    assert_equal %w[new], members(@key)
  end

  # `ZREMRANGEBYRANK 0 -max` is the morgue's own bound (spec §31.8), which keeps
  # `max - 1` of a full set. Seeded scores are recent so only the rank axis can
  # decide survivors.
  def test_trim_index_caps_the_member_count_by_rank
    seed(@key, (0...5).to_h { |i| ["m#{i}", @now + i] })
    trim(@key, max: 3)

    assert_equal %w[m3 m4], members(@key)
  end

  def test_trim_index_leaves_a_set_under_both_bounds_untouched
    seed(@key, 'a' => @now - 10, 'b' => @now - 5)
    trim(@key, max: 10, timeout: 60)

    assert_equal %w[a b], members(@key)
  end

  private

  # One real job so the block doesn't synthesise the empty-batch marker; the
  # push routes through the batch client middleware and BATCH_PUSH, exactly as
  # in production.
  def flush_batch
    batch = Wurk::Batch.new
    batch.jobs { Wurk::Client.push('class' => "BixJob@#{@ns}", 'args' => [], 'queue' => @queue) }
    batch.bid
  end

  def seed(key, scores)
    @pool.with { |conn| scores.each { |member, score| conn.call('ZADD', key, score.to_s, member) } }
  end

  def trim(key, **overrides)
    @pool.with { |conn| conn.pipelined { |pipe| Wurk::Batch.trim_index(pipe, key, **overrides) } }
  end

  def members(key)
    @pool.with { |conn| conn.call('ZRANGE', key, 0, -1) }
  end
end
