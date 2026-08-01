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

  x.report("wurk push_bulk(#{BULK_SIZE})") do
    client.push_bulk(items)
    # Trim to prevent Redis memory growth during the benchmark.
    pool.with { |c| c.call("LTRIM", "queue:default", 0, 0) }
  end
end

pool.with { |c| c.call("DEL", "queue:default") }
