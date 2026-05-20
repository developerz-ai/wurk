# frozen_string_literal: true

require "benchmark/ips"
require "wurk"

# Push a single job to a queue against real Redis.
# Gate: >5% regression vs main blocks merge.

pool   = Wurk::RedisPool.new(size: 5)
client = Wurk::Client.new(pool: pool)
job    = { "class" => "BenchJob", "args" => [], "queue" => "default" }

# Flush any leftover bench jobs.
pool.with { |c| c.call("DEL", "queue:default") }

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)

  x.report("wurk enqueue") do
    client.push(job.dup)
  end
end

pool.with { |c| c.call("DEL", "queue:default") }
