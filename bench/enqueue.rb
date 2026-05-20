# frozen_string_literal: true

require "benchmark/ips"
require "wurk"

# Gate: >5% regression vs main blocks merge.

pool   = Wurk::RedisPool.new(size: 5)
client = Wurk::Client.new(pool: pool)
job    = { "class" => "BenchJob", "args" => [], "queue" => "default" }

pool.with { |c| c.call("DEL", "queue:default") }

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)

  x.report("wurk enqueue") do
    client.push(job.dup)
  end
end

pool.with { |c| c.call("DEL", "queue:default") }
