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

# BenchJob is the job class name baked into the payloads the driver enqueues.
class BenchJob
  include Sidekiq::Job

  sidekiq_options queue: 'default', retry: false

  def perform(*)
    case SHAPE
    when 'cpu' then burn
    when 'io'  then sleep(IO_SECONDS)
    end
    Sidekiq.redis { |conn| conn.call('INCR', DONE_KEY) }
  end

  private

  # Fixed CPU cost per job, iteration-counted rather than clock-bounded: a
  # clock-bounded spin would measure GVL contention as extra work and flatter
  # whichever side runs it, which is exactly the number under dispute.
  def burn
    acc = 0.0
    1.upto(CPU_ITERS) { |i| acc += Math.sqrt(i) * Math.log(i) }
    acc
  end
end
