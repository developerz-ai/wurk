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
