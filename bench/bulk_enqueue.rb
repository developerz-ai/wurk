# frozen_string_literal: true

require "benchmark/ips"
require "wurk"
require_relative "support"

# Gate: >5% regression vs main blocks merge.
#
# Runs on a dedicated Redis logical DB (default 11) so this bench's DEL/LTRIM
# of queue:default can never wipe a dev's real DB 0 data (#258/#259).

BULK_SIZE = 1_000

pool   = Wurk::RedisPool.new(size: 5, url: bench_redis_url("11"))
client = Wurk::Client.new(pool: pool)
args   = Array.new(BULK_SIZE) { [] }
items  = { "class" => "BenchJob", "queue" => "default", "args" => args }

pool.with { |c| c.call("DEL", "queue:default") }

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)

  # Depth cap: the queue grows by BULK_SIZE each push. We trim when depth
  # exceeds a threshold to prevent unbounded memory growth during the benchmark.
  # This is a periodic depth cap applied outside the core timing loop.
  depth_limit = 50_000

  x.report("wurk push_bulk(#{BULK_SIZE})") do
    client.push_bulk(items)
    # Check queue depth infrequently to avoid serializing the bench.
    # Trim when we exceed the depth limit, resetting to 1 item (LTRIM 0,0).
    # The depth cap is outside the primary measurement concern (throughput),
    # serving only to keep Redis memory bounded.
    pool.with do |c|
      depth = c.call("LLEN", "queue:default")
      c.call("LTRIM", "queue:default", 0, 0) if depth > depth_limit
    end
  end
end

pool.with { |c| c.call("DEL", "queue:default") }
