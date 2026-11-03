# frozen_string_literal: true

require_relative '../test_helper'

# parallel_fork deals by position (`j % n == i`), so the order decides the shares.
class SuiteBalanceTest < Wurk::Test::UnitCase
  parallelize_me!

  Suite = Struct.new(:name)
  BALANCE = Wurk::Test::SuiteBalance

  def suites = BALANCE::WEIGHTS.keys.map { Suite.new(_1) } + Array.new(300) { |i| Suite.new("Small#{i}") }

  def share(ordered, worker, workers) = ordered.select.with_index { |_, position| position % workers == worker }

  def load_of(share) = share.sum { |suite| BALANCE::WEIGHTS.fetch(suite.name, 0) }

  def test_every_suite_runs_exactly_once
    [1, 2, 3, 4, 14].each do |workers|
      assert_equal suites.map(&:name).sort, BALANCE.order(suites.shuffle, workers).map(&:name).sort
    end
  end

  def test_the_slow_suites_are_spread_across_workers
    [2, 4].each do |workers|
      ordered = BALANCE.order(suites.shuffle, workers)
      loads = Array.new(workers) { |worker| load_of(share(ordered, worker, workers)) }
      total = BALANCE::WEIGHTS.values.sum
      biggest = BALANCE::WEIGHTS.values.max

      assert_operator loads.max, :<=, [biggest, (total / workers) + (biggest / 2)].max, loads.inspect
    end
  end

  def test_workers_get_even_counts_so_position_keeps_meaning_the_share
    ordered = BALANCE.order(suites.shuffle, 3)
    counts = Array.new(3) { |worker| share(ordered, worker, 3).size }

    assert_operator counts.max - counts.min, :<=, 1
  end

  def test_a_run_of_a_few_files_with_no_slow_suites_still_works
    small = [Suite.new('A'), Suite.new('B'), Suite.new('C')]

    assert_equal %w[A B C], BALANCE.order(small, 2).map(&:name).sort
  end
end
