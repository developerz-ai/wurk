# frozen_string_literal: true

require "benchmark/ips"
require "wurk"

# push_bulk via the EVALSHA-cached Lua path. 1000 jobs per call.
# TODO

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)
  x.report("wurk push_bulk(1000) (TODO)") { 1 + 1 }
end
