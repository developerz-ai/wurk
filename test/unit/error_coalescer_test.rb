# frozen_string_literal: true

require_relative '../test_helper'

class ErrorCoalescerTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @now = 0
    @coalescer = Wurk::ErrorCoalescer.new(window: 60, clock: -> { @now })
  end

  def test_first_report_passes_then_one_per_window_with_the_swallowed_count
    assert_equal 0, @coalescer.admit(:a)
    assert_nil @coalescer.admit(:a)
    assert_nil @coalescer.admit(:a)
    @now = 60

    assert_equal 2, @coalescer.admit(:a)
    assert_nil @coalescer.admit(:a)
  end

  def test_keys_are_independent
    assert_equal 0, @coalescer.admit(:a)
    assert_equal 0, @coalescer.admit(:b)
  end

  # M6: keys can come from data; the map stays bounded.
  def test_remembers_at_most_max_keys
    coalescer = Wurk::ErrorCoalescer.new(window: 60, max_keys: 3, clock: -> { @now })
    10.times { |i| coalescer.admit("k#{i}") }

    assert_equal 3, coalescer.size
  end

  # A full map first drops keys whose window passed with nothing swallowed, so
  # a key still counting suppressions keeps its count.
  def test_a_full_map_evicts_settled_keys_before_one_still_counting
    coalescer = Wurk::ErrorCoalescer.new(window: 60, max_keys: 2, clock: -> { @now })
    coalescer.admit(:busy)
    coalescer.admit(:busy)
    coalescer.admit(:quiet)
    @now = 61
    coalescer.admit(:new)

    assert_equal 1, coalescer.admit(:busy)
  end

  def test_configuration_coalesces_fetch_errors_for_any_handler_and_counts_them_all
    seen = []
    config = Wurk::Configuration.new
    config.error_handlers.replace([->(ex, ctx, _cfg = nil) { seen << [ex.class, ctx] }])
    before = Wurk::Metrics::ProcessCounters.value(:fetch_errors)

    5.times { config.report_fetch_error(RedisClient::ConnectionError.new('down')) }
    config.report_fetch_error(ArgumentError.new('other class'))

    assert_equal [[RedisClient::ConnectionError, { context: 'Error fetching job' }],
                  [ArgumentError, { context: 'Error fetching job' }]], seen
    assert_equal before + 6, Wurk::Metrics::ProcessCounters.value(:fetch_errors)
  end
end
