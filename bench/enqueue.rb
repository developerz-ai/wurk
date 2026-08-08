# frozen_string_literal: true

require 'benchmark/ips'
require 'wurk'
require_relative 'support'

# Gate: >5% regression vs main blocks merge.
#
# Runs on a dedicated Redis logical DB (default 10) so this bench's DEL of
# queue:default can never wipe a dev's real DB 0 data (#258/#259).

pool   = Wurk::RedisPool.new(size: 5, url: bench_redis_url('10'))
client = Wurk::Client.new(pool: pool)
job    = { 'class' => 'BenchJob', 'args' => [], 'queue' => 'default' }

pool.with { |c| c.call('DEL', 'queue:default') }

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)

  x.report('wurk enqueue') do
    client.push(job.dup)
  end
end

pool.with { |c| c.call('DEL', 'queue:default') }
