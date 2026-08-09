# frozen_string_literal: true

require 'benchmark/ips'
require 'wurk'
require_relative 'support'

# 09-debounce-throttle.md, tests: "rake bench: no policy configured → within
# noise; with debounce → report the added enqueue cost."
#
# The "no policy" half needs no new script: `Wurk::Collapse::ClientMiddleware`
# is prepended onto the default chain unconditionally (lib/wurk.rb:270), so
# bench/enqueue.rb — already part of the `rake bench` regression gate — pays
# whatever an unconfigured worker pays every time it runs. That cost is one
# Hash lookup (`job[Wurk::Collapse::OPTION].nil?`) and zero Redis commands,
# pinned at the command level by `rake bench:command_count_policy_off`
# (bench/command_count.rb).
#
# This script is the other half: what a debounce policy itself costs once a
# worker opts in — a cached-Lua round trip (lib/wurk/lua/debounce.lua,
# EVALSHA) in place of the plain LPUSH pipeline bench/enqueue.rb measures.
# Report only, not part of the `rake bench` regression gate (Rakefile
# UNGATED_SCRIPTS): there is no plain-push baseline this can regress
# against — debounce is a whole extra round trip by design, not a
# possibly-zero-cost path like the untracked/no-policy/no-cap gates above.
# The number here is read, not diffed against main. Run explicitly:
# `rake bench:debounce_enqueue`.
#
# Every debounced push shares one identity (same class/queue/args), which is
# the realistic shape a debounce key sees under load: a live burst extending
# the same pending `schedule` entry push after push, not a fresh burst per
# call.
#
# Runs on a dedicated Redis logical DB (7, unused by every other bench/*.rb)
# so a stray dev/CI Redis with real data is never drained or flushed.

pool   = Wurk::RedisPool.new(size: 5, url: bench_redis_url('7'))
client = Wurk::Client.new(pool: pool)

plain    = { 'class' => 'BenchJob', 'args' => [], 'queue' => 'default' }
debounce = plain.merge('collapse' => { 'policy' => 'debounce', 'wait' => 30, 'max_wait' => 60 })

pool.with { |c| c.call('FLUSHDB') }
pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)

  x.report('wurk enqueue (no policy)') do
    client.push(plain.dup)
  end

  x.report('wurk enqueue (collapse: debounce)') do
    client.push(debounce.dup)
  end
end

pool.with { |c| c.call('FLUSHDB') }
