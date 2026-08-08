# frozen_string_literal: true

require 'logger'
require 'wurk'
require_relative 'support'

# Memory profile of the fetch+execute hot path — the "memory blocks merge"
# critical path in CLAUDE.md's "Faster" pillar. Drives the REAL client.push +
# Processor#process_one loop (the same path fetch_execute.rb benchmarks for
# speed) and reports TWO series, because allocation rate alone cannot see a
# leak: a hot path that allocates the same objects every job but never lets go
# of them scores identically to one that frees them.
#
#   wurk hot-path (jobs/1k-alloc)     — RATE. GC.stat(:total_allocated_objects)
#     delta over the loop, as jobs per 1k allocated objects. A monotonic counter
#     GC can't perturb, so no profiler dependency is needed.
#
#   wurk hot-path (retention-free/1k) — RETENTION. GC.stat(:heap_live_slots)
#     delta over the same loop with majors settled on both sides, scored as
#     JOBS * 1000 / (JOBS + retained): 1000 when the loop hands every slot back,
#     halving for each whole slot retained per job.
#
# Both are higher = leaner, deliberately. The bench gate (bin/bench-compare)
# flags a DROP, so a hot path that bloats and one that leaks both trip it like
# an i/s regression — >5% blocks merge. Retention is normalized rather than
# emitted as a raw slot count for exactly that reason: raw slots are
# lower = better, so the gate would read a new leak as an improvement, and a
# healthy run's count is 0, which no ratio-based gate can compare against.
#
# Both lines are printed in benchmark/ips report format ("<label>  <value>
# (± <err>%) i/s") because that is the only shape bin/bench-compare parses
# (IPS_LINE). Neither series is an i/s; the units are in the label. Counts are
# near-deterministic, so we sample a few runs and use the run-to-run spread as
# the ±.
#
# Real Redis, dedicated logical DB (default 13, mirroring fetch_execute's
# isolation from #259). DB 0 is never touched.

JOBS    = Integer(ENV.fetch('WURK_BENCH_MEM_JOBS', '2000'))
SAMPLES = Integer(ENV.fetch('WURK_BENCH_MEM_SAMPLES', '5'))

class BenchJob
  include Wurk::Job

  def perform(*); end
end

config = Wurk::Configuration.new
config.logger = Logger.new(IO::NULL)
config.redis = { url: bench_redis_url('13') }
config.queues = %w[default]
capsule = config.default_capsule
capsule.prepare!

# Isolated scratch DB: a clean slate keeps this closed loop the only consumer
# of queue:default, so every LMOVE finds the job we just pushed.
capsule.redis { |c| c.call('FLUSHDB') }
capsule.redis { |c| Wurk::Lua::Loader.script_load_all(c) }

client    = Wurk::Client.new(pool: capsule.redis_pool)
processor = Wurk::Processor.new(capsule)
job       = { 'class' => 'BenchJob', 'args' => [], 'queue' => 'default' }

# Closed loop: push one, drain one, JOBS times — measuring both series across
# the whole push + fetch + middleware + perform + ack round-trip.
#
# GC.start twice on each side, not once: one major leaves a handful of slots
# unswept, which reads as 4-6 slots of phantom retention (and wobbles the
# allocation count by ~3) even on a loop that retains nothing. A second pass
# settles both to an exact zero, so the retention series measures a leak rather
# than sweep timing.
def hot_path_sample(client, processor, job, jobs)
  2.times { GC.start }
  allocated_before = GC.stat(:total_allocated_objects)
  live_before      = GC.stat(:heap_live_slots)
  jobs.times do
    client.push(job.dup)
    processor.process_one
  end
  allocated = GC.stat(:total_allocated_objects) - allocated_before
  2.times { GC.start }
  [allocated, GC.stat(:heap_live_slots) - live_before]
end

def report_series(label, values)
  mean   = values.sum / values.size
  stddev = Math.sqrt(values.sum { |v| (v - mean)**2 } / values.size)
  err    = mean.zero? ? 0.0 : (stddev / mean * 100.0)
  printf("%-33s %.2f (± %.1f%%) i/s\n", label, mean, err)
end

# Warm up the JIT / autoload / EVALSHA cache so steady-state numbers are what we
# measure, not one-time setup.
hot_path_sample(client, processor, job, [JOBS / 4, 1].max)

samples = Array.new(SAMPLES) { hot_path_sample(client, processor, job, JOBS) }

capsule.redis { |c| c.call('FLUSHDB') }

report_series('wurk hot-path (jobs/1k-alloc)', samples.map { |allocated, _| JOBS * 1000.0 / allocated })
# Clamp the delta at 0: warmup can free more than the loop retains, and a
# negative score would not parse as a benchmark/ips line at all.
report_series('wurk hot-path (retention-free/1k)',
              samples.map { |_, retained| JOBS * 1000.0 / (JOBS + [retained, 0].max) })
