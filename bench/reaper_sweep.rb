# frozen_string_literal: true

require 'logger'
require 'wurk'
require_relative 'algo/support'

# One orphan sweep on a big keyspace — row 07-A4 of docs/plans/2026/11/10/101-
# evidence-driven-improvement-sweep/07-algorithms.md (and 02 R3). A sweep is
# Fetcher::Reaper#reclaim!: SMEMBERS processes for the live owners, then a
# SCAN MATCH `queue:*|*` COUNT 1000 over the whole DB. The keyspace is
# UNRELATED keys that never match, plus PRIVATE_LISTS live private lists of this
# process (its own nonce, so liveness is a kill(0), and nothing is drained).
# Every lock-winning tick sweeps (once per DEFAULT_INTERVAL = 60s per cluster),
# and every booting process runs one more, unlocked (boot_reclaim!).
#
# Round trips and commands are checked against BUDGETS (exit 1 when one is
# exceeded); they follow the keyspace size, so they are gated at the defaults
# only. The sweep rate is advisory.
#
#   eval "$(bin/redis env algobench)"
#   bundle exec ruby -Ilib bench/reaper_sweep.rb
#
# Seeds UNRELATED string keys (~80 MB of Redis at 1M). Dedicated logical DB
# (default 6), FLUSHDB'd before and after. Never DB 0.

UNRELATED     = Integer(ENV.fetch('WURK_BENCH_REAPER_KEYS', '1000000'))
PRIVATE_LISTS = 10

# [round trips, commands] per sweep at the defaults, recorded on this tree: the
# "before" of 07-A4. A fix (a cheap orphan check per tick, the full SCAN hourly)
# lowers the per-tick row in the same change.
BUDGET = [1001, 1001].freeze
GATED = UNRELATED == 1_000_000

config = Wurk.configuration
config.logger = Logger.new(IO::NULL)
config.redis = AlgoBench.redis_options('6')
POOL = AlgoBench.check_pool!(config.redis_pool)

def seed
  keys = Array.new(UNRELATED) { |i| "app:cache:#{i}" }
  keys.each_slice(1000) { |slice| AlgoBench.seed(POOL, [['MSET', *slice.flat_map { |k| [k, 'x'] }]]) }
  owner = "#{Wurk::Component.hostname}|#{Process.pid}|#{Wurk::Component::PROCESS_NONCE}"
  lists = Array.new(PRIVATE_LISTS) { |i| ['LPUSH', "queue:q#{i}|#{owner}|0", '{"class":"InFlight","jid":"x"}'] }
  AlgoBench.seed(POOL, lists)
end

POOL.with { |c| c.call('FLUSHDB') }
begin
  seed
  reaper = Wurk::Fetcher::Reaper.new(config)
  reaper.reclaim!
  dbsize = POOL.with { |c| c.call('DBSIZE') }
  puts "wurk reaper — one sweep over #{dbsize} keys (#{PRIVATE_LISTS} live private lists)\n\n"

  reclaimed = nil
  cost = AlgoBench.count { reclaimed = reaper.reclaim! }
  raise "the sweep reclaimed #{reclaimed} jobs from live lists" unless reclaimed.zero?

  AlgoBench.print_count('reaper sweep', cost)
  AlgoBench.budget_count!('reaper sweep', cost, BUDGET) if GATED
  AlgoBench.timed("reaper sweep (#{UNRELATED} unrelated keys)", time: 10) { reaper.reclaim! }
ensure
  POOL.with { |c| c.call('FLUSHDB') }
end
AlgoBench.finish!
