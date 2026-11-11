# frozen_string_literal: true

require 'logger'
require 'wurk'
require_relative 'algo/support'

# The dashboard Metrics reads at their widest windows — rows 07-A9 and A10 of
# docs/plans/2026/11/10/101-evidence-driven-improvement-sweep/07-algorithms.md.
#
#   top-jobs 720h  — Metrics::Query.top_jobs(hours: 720), what GET
#                    /api/metrics?hours=720 runs: one HGETALL per 10-minute
#                    bucket (4320) over CLASSES classes x 3 fields each, read
#                    and summed a day (144 buckets) per pipeline.
#   queue history  — Metrics::Query.queue_history('1m', 24h, queues: [one]),
#                    what GET /api/queue-history/1m?queue=<name> runs: one
#                    HMGET of that queue's 2 fields per minute bucket (1440).
#                    It was an HGETALL of all QUEUES queues' fields.
#   flush          — Metrics::History.flush of FLUSH_CLASSES classes that ran
#                    in one minute (21-K4): one EXPIRE per shared `j|` key.
#
# Every bucket is seeded full (the worst case: every class ran in every bucket).
# Round trips, commands and the field-value pairs Redis hands back are
# deterministic and checked against BUDGETS (exit 1 when one is exceeded);
# rates and Ruby allocations per query are advisory, printed as i/s-shaped lines
# (allocations as queries per million objects, so higher is leaner, like the
# rates).
#
#   eval "$(bin/redis env algobench)"
#   bundle exec ruby -Ilib bench/metrics_query.rb
#
# Seeds ~2.6M + ~1.4M hash fields (several hundred MB of Redis) one table at a
# time. Dedicated logical DB (default 4), FLUSHDB'd between and after. Never DB 0.

HOURS   = 720
CLASSES = Integer(ENV.fetch('WURK_BENCH_METRICS_CLASSES', '200'))
QUEUES  = Integer(ENV.fetch('WURK_BENCH_METRICS_QUEUES', '500'))

# [round trips, commands, fields returned] at the defaults. Exact; a fix lowers
# its row in the same change. Another shape prints counts ungated. Before
# 07-A9/A10 and 21-K4: top-jobs [1, 4320, 2,592,000], queue history [1, 1440,
# 1,440,000], flush [1, 400]. A9 slices top-jobs (peak memory, allocations);
# Redis still hands back every class's fields.
BUDGETS = {
  'top-jobs 720h' => [30, 4320, 4320 * 200 * 3],
  'queue history 1m/24h, one queue' => [1, 1440, 1440 * 2],
  'flush, 50 classes in one minute' => [1, 302]
}.freeze
# Ruby objects one query allocates (08-M9: the memory budget of a dashboard
# request), measured on a second call so lazy loads and memo fills are not in
# it. Checked at the default shape; about 25% over the measured count, since
# the exact number moves with the Ruby version. Measured on Ruby 3.4.2:
# top-jobs 5,291,702 (2.6M of them the reply's field strings), queue history
# 28,852.
ALLOC_BUDGETS = {
  'top-jobs 720h' => 6_600_000,
  'queue history 1m/24h, one queue' => 36_000
}.freeze
FLUSH_CLASSES = 50
GATED = CLASSES == 200 && QUEUES == 500

config = Wurk.configuration
config.logger = Logger.new(IO::NULL)
config.redis = AlgoBench.redis_options('4')
POOL = AlgoBench.check_pool!(config.redis_pool)
NOW = Time.now

def seed_top_jobs
  fields = Array.new(CLASSES) { |c| %w[p f ms].flat_map { |k| ["BenchMetrics#{c}Job|#{k}", (c + 1).to_s] } }.flatten
  rows = Array.new(HOURS * 6) do |i|
    ['HSET', Wurk::Metrics::History.ten_minute_key(NOW - (i * 600)), *fields]
  end
  AlgoBench.seed(POOL, rows, slice: 100)
end

def seed_queue_history
  fields = Array.new(QUEUES) { |q| ["q#{q}|#{Wurk::Metrics::QueueRollup::SIZE_KIND}", '7', "q#{q}|lt", '1.5'] }.flatten
  step, = Wurk::Metrics::QueueRollup::BUCKETS.fetch('1m')
  last = (NOW.to_i / step) * step
  rows = Array.new(1440) { |i| ['HSET', Wurk::Metrics::QueueRollup.bucket_key('1m', last - (i * step)), *fields] }
  rows << ['SADD', 'queues', *Array.new(QUEUES) { |q| "q#{q}" }]
  AlgoBench.seed(POOL, rows, slice: 100)
end

# Fields the HGETALL / HMGET replies carried into Ruby: what A10 shrinks.
module PairCount
  class << self
    attr_accessor :pairs
  end
  self.pairs = 0

  private

  def pipeline_hgetall(keys)
    super.tap { |replies| PairCount.pairs += replies.sum { |r| r.is_a?(Hash) ? r.size : r.size / 2 } }
  end

  def pipeline_hmget(keys, fields)
    super.tap { |replies| PairCount.pairs += replies.sum(&:size) }
  end
end
Wurk::Metrics::Query.singleton_class.prepend(PairCount)

def measure(label, &query)
  result = nil
  PairCount.pairs = 0
  cost = AlgoBench.count { result = query.call }
  pairs = PairCount.pairs
  raise "#{label} returned nothing: the seed missed the window" if result.empty?

  AlgoBench.print_count(label, cost)
  printf("  %-52s %10d fields returned\n", '', pairs)
  allocated = allocations(&query)
  printf("  %-52s %10d objects allocated\n", '', allocated)
  AlgoBench.budget!("#{label} (allocations)", allocated, ALLOC_BUDGETS.fetch(label)) if GATED
  if GATED
    budget = BUDGETS.fetch(label)
    AlgoBench.budget!("#{label} (round trips)", cost.round_trips, budget[0])
    AlgoBench.budget!("#{label} (commands)", cost.commands, budget[1])
    AlgoBench.budget!("#{label} (fields)", pairs, budget[2])
  end
  rates(label, &query) unless AlgoBench.counts_only?
end

def allocations(&query)
  query.call
  before = GC.stat(:total_allocated_objects)
  query.call
  GC.stat(:total_allocated_objects) - before
end

def rates(label, &query)
  query.call
  before = GC.stat(:total_allocated_objects)
  samples = Array.new(3) do
    t0 = AlgoBench.monotonic
    query.call
    1 / (AlgoBench.monotonic - t0)
  end
  allocated = (GC.stat(:total_allocated_objects) - before) / 3.0
  AlgoBench.print_rate("#{label} q/s", samples)
  AlgoBench.print_rate("#{label} (queries/1M-alloc)", [1_000_000 / allocated] * 2)
  printf("  %-52s %10d objects allocated per query\n", '', allocated)
end

POOL.with { |c| c.call('FLUSHDB') }
begin
  puts "wurk metrics — #{CLASSES} classes x #{HOURS * 6} ten-minute buckets; #{QUEUES} queues x 1440 minute buckets\n\n"
  seed_top_jobs
  measure('top-jobs 720h') { Wurk::Metrics::Query.top_jobs(hours: HOURS, now: NOW) }
  POOL.with { |c| c.call('FLUSHDB') }

  seed_queue_history
  measure('queue history 1m/24h, one queue') do
    Wurk::Metrics::Query.queue_history('1m', 86_400, queues: ['q7'], now: NOW)
  end
  POOL.with { |c| c.call('FLUSHDB') }

  label = 'flush, 50 classes in one minute'
  acc = Wurk::Metrics::Accumulator.new
  FLUSH_CLASSES.times { |c| acc.add(nil, "BenchFlush#{c}Job", NOW.to_i / 60, 5, true) }
  cost = AlgoBench.count { Wurk::Metrics::History.flush(acc) }
  AlgoBench.print_count(label, cost)
  AlgoBench.budget_count!(label, cost, BUDGETS.fetch(label)) if GATED
ensure
  POOL.with { |c| c.call('FLUSHDB') }
end
AlgoBench.finish!
