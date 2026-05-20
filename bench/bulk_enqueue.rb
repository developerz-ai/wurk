# frozen_string_literal: true

require "benchmark/ips"
require "wurk"

# push_bulk via the EVALSHA-cached Lua path: 1 000 jobs per call against real Redis.
# Gate: >5% regression vs main blocks merge.

BULK_SIZE = 1_000

pool   = Wurk::RedisPool.new(size: 5)
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
