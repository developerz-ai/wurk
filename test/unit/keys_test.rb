# frozen_string_literal: true

require_relative '../test_helper'

class KeysTest < Wurk::Test::UnitCase
  parallelize_me!

  # Wire-compat is sacred. Every constant here is part of the on-disk schema
  # shared with Sidekiq OSS. Fail loudly if any string mutates.

  def test_queue_prefix_literal
    assert_equal 'queue:', Wurk::Keys::QUEUE_PREFIX
  end

  def test_queues_set_literal
    assert_equal 'queues', Wurk::Keys::QUEUES_SET
  end

  def test_schedule_literal
    assert_equal 'schedule', Wurk::Keys::SCHEDULE
  end

  def test_retry_literal
    assert_equal 'retry', Wurk::Keys::RETRY
  end

  def test_dead_literal
    assert_equal 'dead', Wurk::Keys::DEAD
  end

  def test_processes_literal
    assert_equal 'processes', Wurk::Keys::PROCESSES
  end

  def test_stat_processed_literal
    assert_equal 'stat:processed', Wurk::Keys::STAT_PROCESSED
  end

  def test_stats_ttl_is_five_years_in_seconds
    assert_equal 5 * 365 * 24 * 60 * 60, Wurk::Keys::STATS_TTL
    assert_equal 157_680_000, Wurk::Keys::STATS_TTL
  end

  def test_queue_helper_concats_with_prefix
    assert_equal 'queue:critical', Wurk::Keys.queue('critical')
  end

  def test_queue_helper_accepts_symbol_via_to_s_interpolation
    assert_equal 'queue:default', Wurk::Keys.queue(:default)
  end

  def test_no_namespace_in_oss
    # OSS must never namespace keys. Pro/Ent layer prefixes externally.
    %w[
      QUEUE_PREFIX QUEUES_SET SCHEDULE RETRY DEAD PROCESSES STAT_PROCESSED
    ].each do |const|
      value = Wurk::Keys.const_get(const)

      refute_match(/\Awurk:/, value, "#{const} must not carry a wurk: namespace prefix")
    end
  end
end
