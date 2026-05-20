# frozen_string_literal: true

require "benchmark/ips"
require "wurk"

# Push a single job to a queue. Compare against stock Sidekiq.
# Gate: > 5% regression vs main blocks merge.

# TODO: implement once Wurk::Client.push lands.
Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)
  x.report("wurk enqueue (TODO)") { 1 + 1 }
end
