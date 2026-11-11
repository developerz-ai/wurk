# frozen_string_literal: true

require 'logger'
require 'wurk'
require_relative 'algo/support'

# What periodic jobs cost at LOOPS registered loops — rows 07-A7 and A8 of
# docs/plans/2026/11/10/101-evidence-driven-improvement-sweep/07-algorithms.md.
#
#   tick    — one Cron::Poller#tick on the leader with nothing due: yearly
#             schedules that have fired once, so each carries its next-fire
#             mark (`nf`). The steady state the leader repeats every minute.
#   tick, never fired — the same with no `nf` yet (a loop between deploy and
#             its first fire): due_slot derives the next occurrence by walking
#             Parser#next_fire_at minute by minute. The poller keeps the answer
#             per loop, so a repeat tick walks nothing: `never-fired walks` is
#             the walks on the second tick over NEVER_FIRED loops (was one per
#             loop per tick). The walk is CPU, not Redis, hence also timed.
#   apply!  — Cron::Manager#apply! for a booting process (each swarm child
#             runs one) that registered LOOPS loops over CLASSES classes, with
#             the same loops already in Redis. `+ foreign` adds FOREIGN loops
#             other classes registered (another app on the Redis, or a class
#             since deleted): prune_superseded reads every one of them, once
#             per class this process registers.
#
# Round trips and Parser constructions are deterministic and checked against
# BUDGETS (exit 1 when one is exceeded); rates are advisory.
#
#   eval "$(bin/redis env algobench)"
#   bundle exec ruby -Ilib bench/cron_tick.rb
#
# Dedicated logical DB (default 3), FLUSHDB'd before and after. Never DB 0.

LOOPS   = Integer(ENV.fetch('WURK_BENCH_CRON_LOOPS', '500'))
CLASSES = Integer(ENV.fetch('WURK_BENCH_CRON_CLASSES', '50'))
FOREIGN = Integer(ENV.fetch('WURK_BENCH_CRON_FOREIGN', '500'))
NEVER_FIRED = Integer(ENV.fetch('WURK_BENCH_CRON_NEVER_FIRED', '50'))
YEARLY  = '0 0 1 1 *'

# [round trips, commands] at the defaults (500 loops, 50 classes, 500 foreign).
# Parsers and walks are counted apart. Exact; a fix lowers its row in the same
# change. Another shape prints counts ungated. Before 07-A7/A8: tick 1001/1001
# with 500 parsers and 50 never-fired walks, apply! 1550/1550, apply! + foreign
# 26,550/26,550.
BUDGETS = {
  'tick, nothing due' => [2, 501],
  'tick parsers' => 0,
  'never-fired walks' => 0,
  'apply!' => [2, 1501],
  'apply! + foreign' => [3, 2001]
}.freeze
GATED = LOOPS == 500 && CLASSES == 50 && FOREIGN == 500

config = Wurk.configuration
config.logger = Logger.new(IO::NULL)
config.redis = AlgoBench.redis_options('3')
POOL = AlgoBench.check_pool!(config.redis_pool)

# Counts Parser constructions (A7's per-loop, per-tick parse) and
# Parser#next_fire_at walks (A7's never-fired loops).
module ParserTally
  class << self
    attr_accessor :built, :walks
  end
  self.built = 0
  self.walks = 0

  def new(...)
    ParserTally.built += 1
    super
  end

  # Prepended to the instances.
  module Walk
    def next_fire_at(...)
      ParserTally.walks += 1
      super
    end
  end
end
Wurk::Cron::Parser.singleton_class.prepend(ParserTally)
Wurk::Cron::Parser.prepend(ParserTally::Walk)

def manager(config)
  Wurk::Cron::Manager.new(config, deferred: true).tap do |mgr|
    LOOPS.times { |i| mgr.register(YEARLY, "CronBench#{i % CLASSES}Job", args: [i]) }
  end
end

# What a first fire leaves behind: the marks claim_fire writes.
def fired!(config)
  now = Time.now.to_i
  next_fire = Wurk::Cron::Parser.new(YEARLY).next_fire_at(now).to_s
  rows = Wurk::Cron::LoopSet.new(config).map do |lp|
    ['HSET', "loops:#{lp.lid}", 'lf', (now - 60).to_s, 'nf', next_fire]
  end
  AlgoBench.seed(POOL, rows)
end

def never_fired_tick(config)
  POOL.with { |c| c.call('FLUSHDB') }
  mgr = Wurk::Cron::Manager.new(config)
  NEVER_FIRED.times { |i| mgr.register(YEARLY, "NeverFired#{i}Job", args: [i]) }
  poller = Wurk::Cron::Poller.new(config)
  poller.define_singleton_method(:leader?) { true }
  poller.tick
  ParserTally.walks = 0
  poller.tick
  printf("  %-52s %10d\n", 'never-fired walks', ParserTally.walks)
  gate('never-fired walks', ParserTally.walks, 'never-fired walks')
  return if AlgoBench.counts_only?

  AlgoBench.timed("cron tick (#{NEVER_FIRED} never-fired yearly loops)", time: 3, min: 2) { poller.tick }
end

def foreign!
  mgr = Wurk::Cron::Manager.new(nil, prune: false)
  FOREIGN.times { |i| mgr.register(YEARLY, "ForeignCron#{i}Job", args: [i]) }
end

def gate(label, value, budget_key, index = nil)
  return unless GATED

  budget = BUDGETS.fetch(budget_key)
  AlgoBench.budget!(label, value, index ? budget[index] : budget)
end

def report(label, count)
  AlgoBench.print_count(label, count)
  gate("#{label} (round trips)", count.round_trips, label, 0)
  gate("#{label} (commands)", count.commands, label, 1)
end

POOL.with { |c| c.call('FLUSHDB') }
begin
  manager(config).apply!
  fired!(config)
  poller = Wurk::Cron::Poller.new(config)
  poller.define_singleton_method(:leader?) { true }
  poller.tick

  puts "wurk cron — #{LOOPS} loops over #{CLASSES} classes, #{FOREIGN} foreign loops\n\n"
  ParserTally.built = 0
  report('tick, nothing due', AlgoBench.count { poller.tick })
  printf("  %-52s %10d\n", 'tick parsers', ParserTally.built)
  gate('tick parsers', ParserTally.built, 'tick parsers')
  tick_label = "cron tick (#{LOOPS} loops, nothing due)"

  tick_rates = Array.new(AlgoBench.counts_only? ? 0 : 20) do
    t0 = AlgoBench.monotonic
    poller.tick
    1 / (AlgoBench.monotonic - t0)
  end

  boot = manager(config)
  report('apply!', AlgoBench.count { boot.apply! })
  foreign!
  boot = manager(config)
  report('apply! + foreign', AlgoBench.count { boot.apply! })

  puts
  AlgoBench.print_rate(tick_label, tick_rates)
  pending = nil
  rebuild = -> { pending = manager(config) }
  label = "cron apply! (#{LOOPS} loops, #{CLASSES} classes, + #{FOREIGN} foreign)"
  AlgoBench.timed(label, time: 5, setup: rebuild) { pending.apply! }
  never_fired_tick(config)
ensure
  POOL.with { |c| c.call('FLUSHDB') }
end
AlgoBench.finish!
