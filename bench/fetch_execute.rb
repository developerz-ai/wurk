# frozen_string_literal: true

require "benchmark/ips"
require "logger"
require "wurk"

# End-to-end fetch+execute — one of the four "Faster" pillar critical paths
# (CLAUDE.md). Each iteration enqueues one job, then drives the REAL reliable
# fetcher (atomic LMOVE: public `queue:default` -> per-process private list)
# and the REAL Processor#process_one: parse JSON, walk the server-middleware
# chain, invoke `perform`, then ACK (LREM from the private list).
#
# Closed loop (push one, drain one) holds the queue at a steady depth so the
# fetcher always takes the non-blocking LMOVE branch and never stalls the
# benchmark on an empty 2s BLMOVE. The measured cost is the fetch + perform +
# ack Redis round-trips plus the dispatch onion — the path the gate protects.
# Real Redis round-trips keep throughput in the low thousands i/s, so cross-run
# jitter sits inside the noise band (unlike the old `1 + 1` stub, #258/#259).
#
# Runs on a dedicated Redis logical DB (default 15, like the test layer's
# fixed-DB slot — DB 0 is never touched) so a stray worker draining `queue:*`
# on the default DB can't steal our jobs and starve the fetcher into BLMOVE.
#
# Gate: >5% regression vs main blocks merge.

def bench_redis_url
  base = ENV["REDIS_URL"] || "redis://localhost:6379/0"
  db = ENV.fetch("WURK_BENCH_DB", "15")
  base.match?(%r{/\d+\z}) ? base.sub(%r{/\d+\z}, "/#{db}") : "#{base}/#{db}"
end

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

# Isolated scratch DB: a clean slate at both ends keeps the closed loop the
# only consumer of queue:default, so every LMOVE finds the job we just pushed.
capsule.redis { |c| c.call("FLUSHDB") }
capsule.redis { |c| Wurk::Lua::Loader.script_load_all(c) }

client    = Wurk::Client.new(pool: capsule.redis_pool)
processor = Wurk::Processor.new(capsule)
job       = { "class" => "BenchJob", "args" => [], "queue" => "default" }

# Seed a small backlog so the first LMOVE of every tick always finds a job.
3.times { client.push(job.dup) }

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)

  x.report("wurk fetch+execute") do
    client.push(job.dup)
    processor.process_one
  end
end

capsule.redis { |c| c.call("FLUSHDB") }
