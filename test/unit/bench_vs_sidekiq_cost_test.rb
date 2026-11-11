# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../bench/vs_sidekiq/cost'

# bench/vs_sidekiq.rb's per-job cost and frame attribution, driven with
# hand-built snapshots and StackProf-shaped profiles: the benchmark itself
# takes minutes and two bundles, and its numbers are only as good as this
# arithmetic and these stage rules.
class BenchVsSidekiqCostTest < Wurk::Test::UnitCase
  Cost = BenchVsSidekiq::Cost

  def test_per_job_divides_the_window_by_the_jobs_inside_it
    first = snapshot(cpu: 1.0, utime: 0.6, stime: 0.4, allocated: 1_000, gcs: 2)
    last = snapshot(cpu: 2.0, utime: 1.2, stime: 0.8, allocated: 11_000, gcs: 7)

    cost = Cost.per_job(first, last, 1001)

    assert_in_delta 1000.0, cost[:cpu_us]
    assert_in_delta 600.0, cost[:utime_us]
    assert_in_delta 400.0, cost[:stime_us]
    assert_in_delta 10.0, cost[:allocs]
    assert_in_delta 5.0, cost[:gc_per_1k]
  end

  # Two processes' CPU clocks subtract to nonsense, not to a cost.
  def test_per_job_refuses_a_window_spanning_two_processes
    assert_nil Cost.per_job(snapshot(pid: 1), snapshot(pid: 2), 10)
  end

  def test_await_edges_returns_once_every_edge_is_written
    reads = [{}, { 'last' => 'l' }, { 'last' => 'l', 'first' => 'f' }]

    edges = Cost.await_edges(%w[first last], timeout: 5, interval: 0) { reads.shift }

    assert_equal({ 'last' => 'l', 'first' => 'f' }, edges)
    assert_empty reads
  end

  # The driver must not compute a cost from half a window.
  def test_await_edges_names_the_missing_edge_past_its_deadline
    error = assert_raises(RuntimeError) do
      Cost.await_edges(%w[first last], timeout: 0.01, interval: 0) { { 'last' => 'l' } }
    end

    assert_match(/no first CPU snapshot/, error.message)
  end

  # The job that saw completion 1 is descheduled before it writes `first`;
  # the last job must not snapshot (or stop the profiler) until it has.
  def test_the_last_edge_waits_for_a_descheduled_first
    edges = {}
    lock = Mutex.new
    polls = Queue.new
    order = Queue.new
    last = Thread.new do
      Cost.await_edges(%w[first], timeout: 5, interval: 0.001) do
        polls << true
        lock.synchronize { edges.dup }
      end
      order << :last
    end

    2.times { assert polls.pop(timeout: 5), 'the last edge never polled' }

    assert_empty order

    order << :first
    lock.synchronize { edges['first'] = 'f' }
    last.join(5)

    assert_equal %i[first last], Array.new(2) { order.pop(timeout: 1) }
  end

  def test_median_of_takes_each_field_independently
    costs = [{ cpu_us: 3.0, utime_us: 1, stime_us: 1, allocs: 9, gc_per_1k: 0 },
             { cpu_us: 1.0, utime_us: 2, stime_us: 1, allocs: 7, gc_per_1k: 0 },
             { cpu_us: 2.0, utime_us: 3, stime_us: 1, allocs: 8, gc_per_1k: 0 }]

    median = Cost.median_of(costs)

    assert_in_delta 2.0, median[:cpu_us]
    assert_equal 2, median[:utime_us]
    assert_equal 8, median[:allocs]
    assert_nil Cost.median_of([])
  end

  # The innermost classified frame wins: a Redis call made from perform is the
  # job's cost, not the middleware's that wraps it, and redis-client frames are
  # transparent.
  def test_stage_is_the_innermost_classified_frame
    stack = ['Wurk::Processor#run', 'Wurk::Middleware::Chain#invoke', 'Wurk::Metrics::History#call',
             'BenchJob#perform', 'RedisClient#call', 'BasicSocket#__write_nonblock']

    assert_equal 'job body (perform + INCR)', Cost.stage_of(stack)
    assert_equal 'metrics middleware', Cost.stage_of(stack.first(3) + ['Process.clock_gettime'])
  end

  # Wurk's UnitOfWork lives under Fetcher::, so the ACK rule has to outrank
  # the fetch rule within one frame.
  def test_ack_frames_are_not_charged_to_fetch
    stack = ['Wurk::Processor#fetch', 'Wurk::Fetcher::Reliable#lmove', 'Wurk::Fetcher::Reliable::UnitOfWork#write_ack']

    assert_equal 'ack bookkeeping', Cost.stage_of(stack)
    assert_equal 'fetch (wurk: + pipelined ACK)', Cost.stage_of(stack.first(2))
  end

  def test_both_engines_land_in_the_same_stages
    {
      'Sidekiq::Processor#get_one' => 'fetch (wurk: + pipelined ACK)',
      'Sidekiq::BasicFetch#retrieve_work' => 'fetch (wurk: + pipelined ACK)',
      'Sidekiq::Metrics::ExecutionTracker#track' => 'metrics middleware',
      'Sidekiq::Job::InterruptHandler#call' => 'other built-in middleware',
      'Wurk::Middleware::Timeout#call' => 'other built-in middleware',
      'Wurk::Middleware::Chain#traverse' => 'middleware chain walk',
      'Sidekiq::Middleware::Chain#traverse' => 'middleware chain walk',
      'Sidekiq::JobLogger#call' => 'job logger + log write',
      'Logger#add' => 'job logger + log write',
      'Wurk::Logger::Formatters::Pretty#call' => 'job logger + log write',
      'Sidekiq::Processor#stats' => 'stats + work state',
      'Wurk::Processor::SharedWorkState#track' => 'stats + work state',
      'Wurk::Processor#dispatch' => 'processor dispatch',
      'block in <class:Config>' => 'processor dispatch',
      '(sweeping)' => 'GC'
    }.each do |frame, stage|
      assert_equal stage, Cost.stage_of(['Thread.handle_interrupt', frame]), frame
    end
  end

  def test_a_stack_with_no_engine_frame_is_unclassified
    assert_equal 'unclassified', Cost.stage_of(['Thread#join', 'IO#wait_readable'])
  end

  # A rename in lib/ would silently move samples into another stage: every
  # Wurk method a rule names must still exist.
  def test_the_wurk_methods_the_rules_name_still_exist
    {
      Wurk::Processor => %i[fetch stats dispatch parse_or_kill],
      Wurk::Fetcher::Reliable => %i[defer_ack take_pending_ack flush_pending_acks retrieve_work],
      Wurk::Fetcher::Reliable::UnitOfWork => %i[acknowledge write_ack],
      Wurk::JobLogger => %i[call prepare],
      Wurk::JobRetry => %i[global local],
      Wurk::Processor::SharedWorkState => %i[track]
    }.each do |klass, methods|
      methods.each do |name|
        assert klass.method_defined?(name) || klass.private_method_defined?(name), "#{klass}##{name} is gone"
      end
    end

    assert defined?(Wurk::Metrics::History)
  end

  # Each run's shares are scaled by that run's own CPU, then the median is
  # taken per stage; the self view drops the engine prefix so namesakes pair.
  def test_attribute_scales_each_run_by_its_own_cpu
    sidekiq = profile([[['Sidekiq::Processor#get_one'], 3], [['BenchJob#perform'], 1]])
    wurk = profile([[['Wurk::Processor#fetch'], 2], [['Wurk::Logger::Formatters::Pretty#call'], 2]])

    result = Cost.attribute({ sidekiq: [[sidekiq, cost(100.0)]], wurk: [[wurk, cost(200.0)]] }, 11)

    sk = result.fetch('sidekiq')
    wk = result.fetch('wurk')

    assert_in_delta 75.0, sk['stages']['fetch (wurk: + pipelined ACK)']
    assert_in_delta 25.0, sk['stages']['job body (perform + INCR)']
    assert_in_delta 100.0, wk['stages']['job logger + log write']
    assert_in_delta 100.0, wk['self']['Logger::Formatters::Pretty#call']
    # 4 samples x 1000 µs over 10 jobs x 100 µs.
    assert_in_delta 4.0, sk['coverage']
  end

  def test_attribute_takes_the_median_across_runs
    run = ->(cpu) { [profile([[['Wurk::Processor#fetch'], 1]]), cost(cpu)] }

    result = Cost.attribute({ wurk: [run.call(10.0), run.call(30.0), run.call(20.0)] }, 11)

    assert_equal 3, result['wurk']['runs']
    assert_in_delta 20.0, result['wurk']['cpu_us']
    assert_in_delta 20.0, result['wurk']['stages']['fetch (wurk: + pipelined ACK)']
  end

  def test_frame_table_reports_the_gap_by_stage_and_frame
    sidekiq = profile([[['Sidekiq::Processor#get_one'], 1], [['BenchJob#perform'], 1]])
    wurk = profile([[['Wurk::Processor#fetch'], 3], [['BenchJob#perform'], 1]])
    result = Cost.attribute({ sidekiq: [[sidekiq, cost(100.0)]], wurk: [[wurk, cost(200.0)]] }, 11)

    table = Cost.frame_table(result)

    assert_includes table, '| fetch (wurk: + pipelined ACK) | 50.0 | 150.0 | +100.0 | +100.0 … +100.0 | +100% |'
    assert_includes table, '| job body (perform + INCR) | 50.0 | 50.0 | +0.0 | +0.0 … +0.0 | +0% |'
    assert_includes table, '| **total CPU** | 100.0 | 200.0 | +100.0 | | 100% |'
    assert_includes table, '| `Processor#fetch` | 0.0 | 150.0 | +150.0 | +150% |'
    refute_includes table, '| unclassified |', 'a stage neither side sampled is left out'
  end

  def test_tally_refuses_an_empty_profile
    error = assert_raises(RuntimeError) { Cost.attribute({ wurk: [[profile([]), cost(1.0)]] }, 11) }

    assert_match(/no samples/, error.message)
  end

  private

  def snapshot(pid: 7, cpu: 0.0, utime: 0.0, stime: 0.0, allocated: 0, gcs: 0)
    JSON.generate('pid' => pid, 'cpu' => cpu, 'utime' => utime, 'stime' => stime,
                  'allocated' => allocated, 'gc' => gcs)
  end

  def cost(cpu_us) = { cpu_us: cpu_us }

  # StackProf's raw layout: [len, frame ids root first..., weight, len, ...].
  def profile(stacks)
    ids = {}
    raw = stacks.flat_map do |names, weight|
      [names.size, *names.map { |n| ids[n] ||= ids.size + 1 }, weight]
    end
    { interval: 1000, raw: raw, frames: ids.to_h { |name, id| [id, { name: name }] } }
  end
end
