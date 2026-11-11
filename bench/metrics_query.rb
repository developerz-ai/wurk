# frozen_string_literal: true

require 'logger'
require 'wurk'
require_relative 'algo/support'

# The dashboard Metrics reads at their widest windows — rows 07-A9 and A10 of
# docs/plans/2026/11/10/101-evidence-driven-improvement-sweep/07-algorithms.md.
#
#   top-jobs 720h  — Metrics::Query.top_jobs(hours: 720), what GET
#                    /api/metrics?hours=720 runs: one HGETALL per 10-minute
#                    bucket (4320) over CLASSES classes x 3 fields each.
#   queue history  — Metrics::Query.queue_history('1m', 24h, queues: [one]),
#                    what GET /api/queue-history/1m?queue=<name> runs: one
#                    HGETALL per minute bucket (1440) carrying all QUEUES
#                    queues' 2 fields, to read one queue's.
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

# [round trips, commands, field pairs returned], recorded on this tree at the
# defaults: the "before" of 07-A9 and A10. Exact; a fix lowers its row in the
# same change. Another shape prints counts ungated.
BUDGETS = {
  'top-jobs 720h' => [1, 4320, 4320 * 200 * 3],
  'queue history 1m/24h, one queue' => [1, 1440, 1440 * 500 * 2]
}.freeze
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

# Field pairs the HGETALL replies carried into Ruby: what the fix shrinks.
module PairCount
  class << self
    attr_accessor :pairs
  end
  self.pairs = 0

  private

  def pipeline_hgetall(keys)
    super.tap { |replies| PairCount.pairs += replies.sum { |r| r.is_a?(Hash) ? r.size : r.size / 2 } }
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
  printf("  %-52s %10d field pairs returned\n", '', pairs)
  if GATED
    budget = BUDGETS.fetch(label)
    AlgoBench.budget!("#{label} (round trips)", cost.round_trips, budget[0])
    AlgoBench.budget!("#{label} (commands)", cost.commands, budget[1])
    AlgoBench.budget!("#{label} (field pairs)", pairs, budget[2])
  end
  rates(label, &query) unless AlgoBench.counts_only?
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
ensure
  POOL.with { |c| c.call('FLUSHDB') }
end
AlgoBench.finish!
