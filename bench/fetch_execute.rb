# frozen_string_literal: true

require 'benchmark/ips'
require 'logger'
require 'wurk'
require_relative 'support'

# End-to-end fetch+execute — one of the four "Faster" pillar critical paths
# (CLAUDE.md). Each iteration drives the REAL reliable fetcher (atomic LMOVE:
# public `queue:default` -> per-process private list) and the REAL
# Processor#process_one: parse JSON, walk the server-middleware chain, invoke
# `perform`, then ACK (LREM from the private list).
#
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
# Holding the queue non-empty is a correctness requirement, not a nicety. An
# empty poll costs a full BLMOVE block, and benchmark-ips runs its current
# batch (~1k iterations at this throughput) to completion before it re-checks
# the clock — so a queue that runs dry one iteration early converts a 7s bench
# into a ~23min one. That is how a flat 50k seed blew this job's 30min timeout
# once the runner turned out to drain ~9.2k jobs/s. Two guards, in order:
#
#   1. SEED_CHUNKS is sized to outlast warmup + the timed window with margin on
#      the reference runner, so the top-up below normally never fires at all
#      and the measurement carries no producer contention.
#   2. The top-up watchdog is the actual guarantee. On its own thread — never
#      inside x.report — it refills whenever depth drops under REFILL_FLOOR, so
#      a runner faster than the seed assumed still measures a full queue rather
#      than hanging. Its LLEN/push_bulk cost lands on the producer thread; the
#      only way it reaches the number is Redis-side contention, and only on the
#      runs where the seed alone would have died.
#
# EMPTY_POLL backstops both: should the queue ever run dry anyway, an empty
# poll costs 50ms instead of the fetcher's 2s default, so the run reads as a
# fast, obvious regression instead of a CI timeout. It cannot skew the number —
# a non-empty queue returns from the LMOVE branch and never reaches BLMOVE.
#
# Gate: >5% regression vs main blocks merge.

# Jobs per push_bulk call, for both the seed and each top-up. Client#push_bulk
# splits this into DEFAULT_BATCH_SIZE (1k) pipelines internally.
REFILL_CHUNK = 25_000
SEED_CHUNKS  = 6
REFILL_FLOOR = 25_000
REFILL_POLL  = 0.05
EMPTY_POLL   = 0.05

class BenchJob
  include Wurk::Job

  def perform(*); end
end

config = Wurk::Configuration.new
config.logger = Logger.new(IO::NULL)
config.redis = { url: bench_redis_url('15') }
config.queues = %w[default]
config.fetch_poll_interval = EMPTY_POLL
capsule = config.default_capsule
capsule.prepare!

# Isolated scratch DB: a clean slate at both ends keeps this process the only
# consumer of queue:default, so every LMOVE finds a job.
capsule.redis { |c| c.call('FLUSHDB') }
capsule.redis { |c| Wurk::Lua::Loader.script_load_all(c) }

client    = Wurk::Client.new(pool: capsule.redis_pool)
processor = Wurk::Processor.new(capsule)

# One args array, reused by the seed and every top-up. Allocating a fresh
# 25k-element array per refill would charge the producer's GC churn to the
# process under measurement.
chunk = { 'class' => 'BenchJob', 'args' => Array.new(REFILL_CHUNK) { [] }, 'queue' => 'default' }

SEED_CHUNKS.times { client.push_bulk(chunk) }

# A raise in here kills the run — Thread#join re-raises below — because a dead
# watchdog means a queue that can run dry, which is the failure this exists to
# prevent.
stop = Queue.new
refiller = Thread.new do
  until stop.pop(timeout: REFILL_POLL)
    client.push_bulk(chunk) if capsule.redis { |c| c.call('LLEN', 'queue:default') } < REFILL_FLOOR
  end
end

begin
  Benchmark.ips do |x|
    x.config(time: 5, warmup: 2)

    x.report('wurk fetch+execute') do
      processor.process_one
    end
  end
ensure
  stop << :stop
  refiller.join
end

capsule.redis { |c| c.call('FLUSHDB') }
