# frozen_string_literal: true

require 'benchmark/ips'
require 'wurk'

# Command normalization — the per-command tax every Redis round trip pays
# before a byte reaches the socket. redis-client's default builder splices Hash
# arguments with a `flat_map` and stringifies the result with a `map!`; Wurk's
# {Wurk::CommandBuilder} short-circuits the all-String case, which is every
# command on the fetch+execute and enqueue paths (LMOVE, LREM, DEL, LPUSH,
# SADD) and three of them per job.
#
# No Redis, no sockets, no forks — this measures the Ruby that runs between
# `conn.call(...)` and the wire, so it is the one bench in the gate whose
# number is free of round-trip jitter. That is the point: the fetch+execute
# gate can only see this cost buried under ~800µs of real I/O, while a
# regression here (a fast path that stops firing, a call site that starts
# passing an Integer again) shows up immediately.
#
# The `fallback` report is the guard rail in the other direction: a command
# carrying a Hash must keep going through redis-client's own builder, and its
# cost must not drift either.
#
# Gate: >5% regression vs main blocks merge.

ACK = ['LREM', 'queue:default|worker-1|41234|8f3c1d2e5a90|0', '1',
       '{"class":"HardJob","args":[1,"two"],"queue":"default","jid":"6f1b0c9a4d3e2f1b8c7a6d5e",' \
       '"created_at":1786000000.123,"enqueued_at":1786000000.456}'].freeze

FETCH = ['LMOVE', 'queue:default', 'queue:default|worker-1|41234|8f3c1d2e5a90|0', 'RIGHT', 'LEFT'].freeze

PUSH = ['LPUSH', 'queue:default',
        '{"class":"HardJob","args":[1,"two"],"queue":"default","jid":"6f1b0c9a4d3e2f1b8c7a6d5e"}'].freeze

# Hash argument — the shape the fast path must decline.
HSET = ['HSET', 'wurk:proc:worker-1', { 'busy' => '3', 'beat' => '1786000000.1' }].freeze

builder = Wurk::CommandBuilder

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)

  x.report('wurk cmd ack (LREM)')    { builder.generate(ACK) }
  x.report('wurk cmd fetch (LMOVE)') { builder.generate(FETCH) }
  x.report('wurk cmd push (LPUSH)')  { builder.generate(PUSH) }
  x.report('wurk cmd fallback')      { builder.generate(HSET) }
end
