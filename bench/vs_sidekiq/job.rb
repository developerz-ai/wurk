# frozen_string_literal: true

# The workload for bench/vs_sidekiq.rb. Passed to BOTH CLIs as `-r`, so it is
# loaded after either `wurk` or `sidekiq` is already required: `Sidekiq::Job`
# resolves to wurk's compat module on one side and to stock Sidekiq's on the
# other, and the two sides run byte-identical job code. That is the whole point
# — the only difference between the runs is the engine underneath.
#
# Three shapes, because "faster" has no meaning without one:
#
#   noop — empty perform. Pure framework overhead: fetch, middleware chain,
#          dispatch, ack. Redis-bound, so the GVL is mostly released and
#          threads compete well here.
#   cpu  — a fixed arithmetic loop. Holds the GVL, so a threaded process
#          serializes it no matter the concurrency setting. This is the shape
#          fork-based parallelism exists for.
#   io   — sleep. Releases the GVL, so threads and forks both scale; the
#          honest control that shows where wurk's model does NOT help.
#
# Every job INCRs a shared counter as its last act. The driver polls that
# counter to detect drain — the only completion signal that means the same
# thing on both sides (in-flight bookkeeping differs between the engines).

SHAPE      = ENV.fetch('WURK_BENCH_VS_SHAPE', 'noop')
CPU_ITERS  = Integer(ENV.fetch('WURK_BENCH_VS_CPU_ITERS', '20000'))
IO_SECONDS = Float(ENV.fetch('WURK_BENCH_VS_IO_SECONDS', '0.005'))
DONE_KEY   = ENV.fetch('WURK_BENCH_VS_DONE_KEY', 'wurk-bench:vs:done')
JOBS       = Integer(ENV.fetch('WURK_BENCH_VS_JOBS', '0'))
CPU_KEY    = "#{DONE_KEY}:cpu".freeze
EDGES      = [1, JOBS].freeze
PROFILE    = ENV.fetch('WURK_BENCH_VS_PROFILE_OUT', nil)
PROFILE_US = Integer(ENV.fetch('WURK_BENCH_VS_PROFILE_INTERVAL', '1000'))
require 'json'
require 'stackprof' if PROFILE
require_relative 'cost'

# BenchJob is the job class name baked into the payloads the driver enqueues.
class BenchJob
  include Sidekiq::Job

  sidekiq_options queue: 'default', retry: false

  def perform(*)
    case SHAPE
    when 'cpu' then burn
    when 'io'  then sleep(IO_SECONDS)
    end
    done = Sidekiq.redis { |conn| conn.call('INCR', DONE_KEY) }
    mark(done) if EDGES.include?(done)
  end

  private

  # The profiler runs from the first completion to the last, like the CPU
  # window, so boot and shutdown never show up as framework cost. Sampled in
  # CPU mode: an idle thread parked in BLMOVE/BRPOP costs nothing and is not
  # sampled, and a busy one is sampled whichever engine thread it is.
  def mark(done)
    if done == 1
      snapshot = cost_snapshot
      StackProf.start(mode: :cpu, raw: true, interval: PROFILE_US) if PROFILE
      write_edge('first', snapshot)
    else
      BenchVsSidekiq::Cost.await_edges(%w[first], timeout: BenchVsSidekiq::Cost::EDGE_TIMEOUT) do
        Sidekiq.redis { |conn| conn.call('HGETALL', CPU_KEY) }
      end
      snapshot = cost_snapshot
      if PROFILE
        StackProf.stop
        StackProf.results(PROFILE)
      end
      write_edge('last', snapshot)
    end
  end

  def write_edge(edge, snapshot)
    Sidekiq.redis { |conn| conn.call('HSET', CPU_KEY, edge, snapshot) }
  end

  # Process-wide cost at a completion count: CPU across every thread (fetch,
  # perform, heartbeat, poller — whatever the engine runs), its user/system
  # split, and allocations. Taken by the jobs that see the first and the last
  # completion, so the window is exactly the driver's drain window and costs
  # two extra Redis writes per run, not one per job. The driver divides by the
  # jobs in between (bench/vs_sidekiq/cost.rb).
  def cost_snapshot
    times = Process.times
    JSON.generate(
      'pid' => Process.pid,
      'cpu' => Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID),
      'utime' => times.utime, 'stime' => times.stime,
      'allocated' => GC.stat(:total_allocated_objects), 'gc' => GC.count
    )
  end

  # Fixed CPU cost per job, iteration-counted rather than clock-bounded: a
  # clock-bounded spin would measure GVL contention as extra work and flatter
  # whichever side runs it, which is exactly the number under dispute.
  def burn
    acc = 0.0
    1.upto(CPU_ITERS) { |i| acc += Math.sqrt(i) * Math.log(i) }
    acc
  end
end
