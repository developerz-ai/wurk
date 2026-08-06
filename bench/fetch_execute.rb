# frozen_string_literal: true

require "benchmark/ips"
require "logger"
require "wurk"
require_relative "support"

# End-to-end fetch+execute — one of the four "Faster" pillar critical paths
# (CLAUDE.md). Each iteration drives the REAL reliable fetcher (atomic LMOVE:
# public `queue:default` -> per-process private list) and the REAL
# Processor#process_one: parse JSON, walk the server-middleware chain, invoke
# `perform`, then ACK (LREM from the private list).
#
# The queue is pre-filled (batched pipeline via Client#push_bulk) to a depth
# deep enough to outlast warmup + the timed window, so the fetcher always
# takes the non-blocking LMOVE branch and never stalls on an empty 2s BLMOVE.
# The timed block is `processor.process_one` ONLY — enqueue must never appear
# inside `x.report`, or this bench silently measures `push` cost too and
# conflates two different critical paths (`enqueue.rb` already benches that).
# The measured cost is the fetch + perform + ack Redis round-trips plus the
# dispatch onion — the path the gate protects. Real Redis round-trips keep
# throughput in the low thousands i/s, so cross-run jitter sits inside the
# noise band (unlike the old `1 + 1` stub, #258/#259).
#
# Runs on a dedicated Redis logical DB (default 15, like the test layer's
# fixed-DB slot — DB 0 is never touched) so a stray worker draining `queue:*`
# on the default DB can't steal our jobs and starve the fetcher into BLMOVE.
#
# NOTE: this fixes a measurement bug (enqueue was timed inside process_one's
# loop) — the first bench-compare run against old `main` will show a spurious
# jump/drop on this label. That's the fix taking effect, not a regression;
# flagged in the PR body. Land as its own commit so history is easy to bisect.
#
# Gate: >5% regression vs main blocks merge.

class BenchJob
  include Wurk::Job

  def perform(*); end
end

config = Wurk::Configuration.new
config.logger = Logger.new(IO::NULL)
config.redis = { url: bench_redis_url("15") }
config.queues = %w[default]
capsule = config.default_capsule
capsule.prepare!

# Isolated scratch DB: a clean slate at both ends keeps the closed loop the
# only consumer of queue:default, so every LMOVE finds the job we just pushed.
capsule.redis { |c| c.call("FLUSHDB") }
capsule.redis { |c| Wurk::Lua::Loader.script_load_all(c) }

client    = Wurk::Client.new(pool: capsule.redis_pool)
processor = Wurk::Processor.new(capsule)

# Pre-fill well past anything warmup + the timed window can drain, via a
# single batched pipeline (not per-iteration) so enqueue cost never leaks
# into the timed block below. At "low thousands i/s" (see comment above), 7s
# of warmup+run tops out in the tens of thousands of iterations.
SEED_DEPTH = 50_000
client.push_bulk("class" => "BenchJob", "args" => Array.new(SEED_DEPTH) { [] }, "queue" => "default")

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)

  x.report("wurk fetch+execute") do
    processor.process_one
  end
end

capsule.redis { |c| c.call("FLUSHDB") }
