# frozen_string_literal: true

require 'benchmark/ips'
require 'logger'
require 'wurk'
require_relative 'support'

# Fetch+execute for a capsule serving 100 queues in strict order, every job on
# the LAST one — the sparse many-queue shape that used to cost one LMOVE round
# trip per queue before the walk reached a job (R8,
# docs/plans/2026/10/04/101-squeaky-clean-audit/09-production-readiness.md).
# The one-queue path is bench/fetch_execute.rb; this block guards the other.
#
# Same discipline as fetch_execute.rb, for the same reasons: the timed block is
# `processor.process_one` only, the queue is seeded to outlast the run and a
# watchdog tops it up, and EMPTY_POLL keeps a queue that ran dry from turning
# into a CI timeout.
#
# Runs on its own Redis logical DB (default 6, unused by every other
# bench/*.rb). DB 0 is never touched.
#
# Gate: >5% regression vs main blocks merge.

QUEUE_COUNT  = 100
REFILL_CHUNK = 25_000
SEED_CHUNKS  = 4
REFILL_FLOOR = 25_000
REFILL_POLL  = 0.05
EMPTY_POLL   = 0.05

class BenchJob
  include Wurk::Job

  def perform(*); end
end

queues = Array.new(QUEUE_COUNT) { |i| "q#{i}" }
last_queue = queues.last

config = Wurk::Configuration.new
config.logger = Logger.new(IO::NULL)
config.redis = { url: bench_redis_url('6') }
config.queues = queues
config.fetch_poll_interval = EMPTY_POLL
capsule = config.default_capsule
capsule.prepare!

capsule.redis { |c| c.call('FLUSHDB') }
capsule.redis { |c| Wurk::Lua::Loader.script_load_all(c) }

client    = Wurk::Client.new(pool: capsule.redis_pool)
processor = Wurk::Processor.new(capsule)

chunk = { 'class' => 'BenchJob', 'args' => Array.new(REFILL_CHUNK) { [] }, 'queue' => last_queue }

SEED_CHUNKS.times { client.push_bulk(chunk) }

stop = Queue.new
refiller = Thread.new do
  until stop.pop(timeout: REFILL_POLL)
    client.push_bulk(chunk) if capsule.redis { |c| c.call('LLEN', "queue:#{last_queue}") } < REFILL_FLOOR
  end
end

begin
  Benchmark.ips do |x|
    x.config(time: 5, warmup: 2)

    x.report('wurk fetch+execute (100 queues, job on last)') do
      processor.process_one
    end
  end
ensure
  stop << :stop
  refiller.join
end

capsule.redis { |c| c.call('FLUSHDB') }
