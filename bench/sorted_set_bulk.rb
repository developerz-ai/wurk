# frozen_string_literal: true

require 'logger'
require 'json'
require 'wurk'
require_relative 'algo/support'

# "Retry all" on a full retry set — row 07-A11 of docs/plans/2026/11/10/101-
# evidence-driven-improvement-sweep/07-algorithms.md. RetrySet#retry_all (the
# dashboard's Retry All, POST /api/retries/all/retry) walks the set newest
# first and, per entry, removes it and pushes it through the client: serial
# round trips per job, in a Puma thread.
#
# Round trips and commands per entry are deterministic and checked against
# BUDGET (exit 1 when exceeded); jobs/s is advisory. The queue the jobs land
# on is checked, so a run that retries fewer than ENTRIES fails.
#
#   eval "$(bin/redis env algobench)"
#   bundle exec ruby -Ilib bench/sorted_set_bulk.rb
#
# Dedicated logical DB (default 7), FLUSHDB'd before and after. Never DB 0.

ENTRIES = Integer(ENV.fetch('WURK_BENCH_BULK_ENTRIES', '10000'))
QUEUE   = 'bulk'

# [round trips, commands] per entry, recorded on this tree: the "before" of
# 07-A11 (pages of 100-500 with one push per page is the fix).
BUDGET = [2.02, 3.02].freeze

config = Wurk.configuration
config.logger = Logger.new(IO::NULL)
config.redis = AlgoBench.redis_options('7')
POOL = AlgoBench.check_pool!(config.redis_pool)

ROWS = Array.new(ENTRIES) do |i|
  job = { 'class' => 'BulkJob', 'args' => [i], 'queue' => QUEUE, 'jid' => format('%024x', i),
          'created_at' => 1_700_000_000.0, 'enqueued_at' => 1_700_000_000.0, 'retry' => true,
          'retry_count' => 3, 'error_class' => 'RuntimeError', 'error_message' => 'boom',
          'failed_at' => 1_700_000_000.0 }
  ['ZADD', 'retry', (1_800_000_000 + i).to_s, JSON.dump(job)]
end.freeze

def reseed
  POOL.with { |c| c.call('DEL', 'retry', "queue:#{QUEUE}") }
  AlgoBench.seed(POOL, ROWS)
end

def retry_all!
  done = Wurk::RetrySet.new.retry_all
  landed = POOL.with { |c| c.call('LLEN', "queue:#{QUEUE}") }
  raise "retry_all moved #{done}, queue holds #{landed}; want #{ENTRIES}" unless done == ENTRIES && landed == ENTRIES
end

POOL.with { |c| c.call('FLUSHDB') }
begin
  reseed
  Wurk::RetrySet.new.retry_all # warm: autoload, client middleware, connection
  reseed
  cost = AlgoBench.count { retry_all! }
  puts "wurk RetrySet#retry_all — #{ENTRIES} entries\n\n"
  AlgoBench.print_count('retry_all, per entry', cost, per: ENTRIES)
  per = [cost.round_trips.fdiv(ENTRIES).round(2), cost.commands.fdiv(ENTRIES).round(2)]
  if ENTRIES == 10_000
    AlgoBench.budget!('retry_all (round trips/entry)', per[0], BUDGET[0])
    AlgoBench.budget!('retry_all (commands/entry)', per[1], BUDGET[1])
  end
  AlgoBench.timed("retry_all (#{ENTRIES} entries) jobs/s", time: 10, scale: ENTRIES, setup: -> { reseed }) do
    retry_all!
  end
ensure
  POOL.with { |c| c.call('FLUSHDB') }
end
AlgoBench.finish!
