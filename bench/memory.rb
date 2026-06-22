# frozen_string_literal: true

require "logger"
require "wurk"

# Memory / allocation profile of the fetch+execute hot path — the "memory blocks
# merge" critical path in CLAUDE.md's "Faster" pillar. Drives the REAL
# client.push + Processor#process_one loop (the same path fetch_execute.rb
# benchmarks for speed) and counts the objects Ruby allocates per job via
# GC.stat(:total_allocated_objects) — a monotonic counter GC can't perturb, so
# no profiler dependency is needed.
#
# Reported as jobs-per-1k-allocations (higher = leaner). A change that bloats
# the hot path's allocations DROPS this number, so the bench gate
# (bin/bench-compare) flags it exactly like an i/s regression: >5% blocks merge.
# Allocation counts are near-deterministic, so we sample a few runs and emit a
# benchmark/ips-compatible line ("<label>  <value> (± <err>%) i/s") with the
# (small) run-to-run spread as the ±.
#
# Real Redis, dedicated logical DB (default 13, mirroring fetch_execute's
# isolation from #259). DB 0 is never touched.

def bench_redis_url(default_db = "13")
  base = ENV["REDIS_URL"] || "redis://localhost:6379/0"
  db = ENV.fetch("WURK_BENCH_DB", default_db)
  base.match?(%r{/\d+\z}) ? base.sub(%r{/\d+\z}, "/#{db}") : "#{base}/#{db}"
end

JOBS    = Integer(ENV.fetch("WURK_BENCH_MEM_JOBS", "2000"))
SAMPLES = Integer(ENV.fetch("WURK_BENCH_MEM_SAMPLES", "5"))

class BenchJob
  include Wurk::Job

  def perform(*); end
end

config = Wurk::Configuration.new
config.logger = Logger.new(IO::NULL)
config.redis = { url: bench_redis_url }
config.queues = %w[default]
capsule = config.default_capsule
capsule.prepare!

# Isolated scratch DB: a clean slate keeps this closed loop the only consumer
# of queue:default, so every LMOVE finds the job we just pushed.
capsule.redis { |c| c.call("FLUSHDB") }
capsule.redis { |c| Wurk::Lua::Loader.script_load_all(c) }

client    = Wurk::Client.new(pool: capsule.redis_pool)
processor = Wurk::Processor.new(capsule)
job       = { "class" => "BenchJob", "args" => [], "queue" => "default" }

# Closed loop: push one, drain one, JOBS times — counting allocations across the
# whole push + fetch + middleware + perform + ack round-trip.
def hot_path_allocations(client, processor, job, jobs)
  GC.start
  before = GC.stat(:total_allocated_objects)
  jobs.times do
    client.push(job.dup)
    processor.process_one
  end
  GC.stat(:total_allocated_objects) - before
end

# Warm up the JIT / autoload / EVALSHA cache so steady-state allocations are
# what we measure, not one-time setup.
hot_path_allocations(client, processor, job, [JOBS / 4, 1].max)

metrics = Array.new(SAMPLES) do
  allocs = hot_path_allocations(client, processor, job, JOBS)
  JOBS * 1000.0 / allocs # jobs per 1k allocated objects; higher = leaner
end

capsule.redis { |c| c.call("FLUSHDB") }

mean   = metrics.sum / metrics.size
stddev = Math.sqrt(metrics.sum { |m| (m - mean)**2 } / metrics.size)
err    = mean.zero? ? 0.0 : (stddev / mean * 100.0)

printf("%-28s %.2f (± %.1f%%) i/s\n", "wurk hot-path (jobs/1k-alloc)", mean, err)
