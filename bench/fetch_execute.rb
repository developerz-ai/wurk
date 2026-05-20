# frozen_string_literal: true

require "benchmark/ips"
require "wurk"

# End-to-end: enqueue, BLMOVE to private list, pop, run middleware chain,
# invoke perform, ACK. Single child, single thread, no real work in perform.
# TODO

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)
  x.report("wurk fetch+execute (TODO)") { 1 + 1 }
end
