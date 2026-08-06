# frozen_string_literal: true

require "benchmark/ips"
require "wurk"
require_relative "support"

# Gate: >5% regression vs main blocks merge.
#
# Runs on a dedicated Redis logical DB (default 11) so this bench's DEL/UNLINK
# of queue:default can never wipe a dev's real DB 0 data (#258/#259).

BULK_SIZE = 1_000

# Backlog cap for the watchdog below. Each push adds BULK_SIZE, so the queue
# peaks near DEPTH_LIMIT + (throughput * DEPTH_POLL) entries — single-digit MB —
# rather than growing unbounded across the 7s run.
DEPTH_LIMIT = 25_000
DEPTH_POLL  = 0.025

pool   = Wurk::RedisPool.new(size: 5, url: bench_redis_url("11"))
client = Wurk::Client.new(pool: pool)
args   = Array.new(BULK_SIZE) { [] }
items  = { "class" => "BenchJob", "queue" => "default", "args" => args }

pool.with { |c| c.call("DEL", "queue:default") }

# The backlog cap runs on its own thread, never inside x.report. Nothing but
# push_bulk may sit in the timed block: an LLEN/LTRIM pair per iteration adds a
# whole round trip to every sample, and the gate cannot tell that overhead apart
# from a real push_bulk regression.
#
# UNLINK, not LTRIM: freeing a 25k-entry list happens on Redis' background
# thread, so draining the backlog never stalls the connection serving the bench.
#
# A raise in here kills the run — Thread#join re-raises below — because a dead
# watchdog means an unbounded queue, not a merely inaccurate number.
stop = Queue.new
watchdog = Thread.new do
  until stop.pop(timeout: DEPTH_POLL)
    pool.with { |c| c.call("UNLINK", "queue:default") if c.call("LLEN", "queue:default") > DEPTH_LIMIT }
  end
end

begin
  Benchmark.ips do |x|
    x.config(time: 5, warmup: 2)

    x.report("wurk push_bulk(#{BULK_SIZE})") { client.push_bulk(items) }
  end
ensure
  stop << :stop
  watchdog.join
end

pool.with { |c| c.call("DEL", "queue:default") }
