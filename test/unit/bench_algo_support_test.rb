# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../bench/algo/support'
require 'English'
require 'tmpdir'

# The algorithm benches (bench/dashboard_paging.rb and its six siblings) gate on
# round trips counted by AlgoBench::Tally and publish rates through
# AlgoBench.print_rate. Both are only worth something if the tally counts what
# reaches the wire and the rate line is one bin/bench-compare can read.
class BenchAlgoSupportTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, middlewares: [AlgoBench::Tally])
    @pool.with { |c| c.call('PING') }
  end

  def teardown
    @pool.disconnect!
    AlgoBench.instance_variable_set(:@over, nil)
    super
  end

  def test_a_pipeline_is_one_round_trip_carrying_each_command
    cost = AlgoBench.count do
      @pool.with { |c| c.call('SET', 'algo:a', '1') }
      @pool.with { |c| c.pipelined { |p| 3.times { |i| p.call('GET', "algo:#{i}") } } }
    end

    assert_equal 2, cost.round_trips
    assert_equal 4, cost.commands
    assert_equal({ 'set' => 1, 'get' => 3 }, cost.by_command)
  end

  def test_check_pool_refuses_db_zero_and_an_untallied_pool
    zero = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url.sub(%r{/\d+\z}, '/0'))

    assert_raises(RuntimeError) { AlgoBench.check_pool!(zero) }

    plain = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url)

    assert_raises(RuntimeError) { AlgoBench.check_pool!(plain) }
    assert_same @pool, AlgoBench.check_pool!(@pool)
  ensure
    plain&.disconnect!
  end

  def test_finish_fails_the_run_when_a_count_went_over_budget
    capture_io do
      AlgoBench.budget!('within', 3, 3)
      AlgoBench.finish!
      AlgoBench.budget!('over', 4, 3)
    end
    _, err = capture_io { assert_raises(SystemExit) { AlgoBench.finish! } }

    assert_match(/over: 4, over the budget of 3/, err)
    refute_match(/within/, err)
  end

  def test_the_rate_line_is_one_bin_bench_compare_reads
    Dir.mktmpdir do |dir|
      files = [[100.0, 110.0], [100.0, 50.0]].each_with_index.map do |rates, i|
        line, = capture_io { AlgoBench.print_rate('dashboard batches page 999 (count 25)', rates) }
        File.join(dir, "run#{i}.txt").tap { |path| File.write(path, line) }
      end
      out = IO.popen([RbConfig.ruby, File.expand_path('../../bin/bench-compare', __dir__), *files], &:read)

      assert_match(/`dashboard batches page 999 \(count 25\)` \| 105 \| 75/, out)
    end
  end
end
