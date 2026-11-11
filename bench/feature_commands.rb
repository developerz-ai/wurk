# frozen_string_literal: true

require 'logger'
require 'wurk'
require_relative 'algo/support'

# Redis round trips and commands per job for the opt-in features: unique, batch,
# concurrent limiter, status — row 07-A5 of docs/plans/2026/11/10/101-evidence-
# driven-improvement-sweep/07-algorithms.md. bench/command_count.rb is the same
# question for a plain job, answered server-side; this one counts client-side
# (bench/algo/support.rb, Tally), so it is blind to other clients and a Lua
# script is its one EVALSHA.
#
# Each feature runs JOBS jobs through the real Client and the real
# Processor#process_one, under the process-global configuration (its server
# middleware chain is the one every worker boots with). Enqueue and execute are
# counted apart, per job, then the plain-job cost is subtracted so a row reads
# as what the feature adds. Deterministic; exits 1 when a row goes over BUDGETS.
#
#   eval "$(bin/redis env algobench)"
#   bundle exec ruby -Ilib bench/feature_commands.rb
#
# Dedicated logical DB (default 2), FLUSHDB'd before and after. Never DB 0.

JOBS = Integer(ENV.fetch('WURK_BENCH_FEATURE_JOBS', '200'))

# Per job, [round trips, commands], enqueue + execute, OVER the plain job.
# Exact: an added round trip or command fails the run, and a fix lowers its row
# in the same change. 07-A5 took the concurrent limiter from 6 (constant) and 7
# (built per job) to 2 and 3: acquire and release with the counters folded into
# their scripts, plus the per-job construction's registration.
BUDGETS = {
  'unique' => [2, 2],
  'batch' => [1.1, 1.18],
  'concurrent limiter (constant)' => [2, 2],
  'concurrent limiter (built per job)' => [3, 3],
  'status' => [2, 4]
}.freeze

# Before the job classes: LIMITER below builds the pool, which then keeps
# whatever config.redis said at that moment.
config = Wurk.configuration
config.logger = Logger.new(IO::NULL)
config.redis = AlgoBench.redis_options('2')
config.queues = %w[default]
# Unique's middleware joins the chains here; a prepared capsule would not see it.
Wurk::Unique.enable!(config)
capsule = config.default_capsule
capsule.prepare!

# Job classes namespaced so the payload's `class` resolves on the way back in.
module FeatureBench
  class PlainJob
    include Wurk::Job

    def perform(*); end
  end

  class UniqueJob
    include Wurk::Job

    sidekiq_options unique_for: 3600

    def perform(*); end
  end

  class TrackedJob
    include Wurk::Job

    sidekiq_options track: true

    def perform(*); end
  end

  LIMITER = Wurk::Limiter.concurrent('bench-constant', 5, wait_timeout: 1, lock_timeout: 30)

  class LimitedJob
    include Wurk::Job

    def perform(*) = LIMITER.within_limit { nil }
  end

  # The per-user shape (`stripe-#{user_id}`): constructed inside perform, so
  # every job pays the registration too.
  class PerJobLimitedJob
    include Wurk::Job

    def perform(*)
      Wurk::Limiter.concurrent('bench-per-job', 5, wait_timeout: 1, lock_timeout: 30).within_limit { nil }
    end
  end
end

POOL = AlgoBench.check_pool!(capsule.redis_pool)
PROCESSOR = Wurk::Processor.new(capsule)

def drain(jobs)
  Wurk::Processor::PROCESSED.reset
  jobs.times { PROCESSOR.process_one }
  done = Wurk::Processor::PROCESSED.reset
  abort format('✗ ran %d of %d jobs — the count is meaningless', done, jobs) unless done == jobs
end

# The fetcher re-reads the `paused` SET once per PAUSED_TTL (2s), a round trip
# per interval, not per job: it lands in whichever row is running when the
# cache expires and read as 2.01 round trips per job on a slow run. No job path
# here sends SMEMBERS, so the execute window drops it.
def without_paused_refresh(count)
  refreshes = count.by_command.fetch('smembers', 0)
  # A refresh per 2s cannot reach 10 in one window; more is a job sending it.
  abort format('✗ %d SMEMBERS in one execute window: a job path sends it', refreshes) if refreshes >= 10
  AlgoBench::Count.new(count.round_trips - refreshes, count.commands - refreshes,
                       count.by_command.except('smembers'))
end

# [enqueue, execute] Counts for `jobs` jobs enqueued by `push`.
def measure(jobs, push)
  POOL.with { |c| c.call('FLUSHDB') }
  enqueue = AlgoBench.count { push.call(jobs) }
  execute = without_paused_refresh(AlgoBench.count { drain(jobs) })
  [enqueue, execute]
end

PUSHES = {
  'plain' => ->(n) { n.times { |i| FeatureBench::PlainJob.perform_async(i) } },
  'unique' => ->(n) { n.times { |i| FeatureBench::UniqueJob.perform_async(i) } },
  'batch' => lambda { |n|
    batch = Wurk::Batch.new
    batch.jobs { n.times { |i| FeatureBench::PlainJob.perform_async(i) } }
  },
  'concurrent limiter (constant)' => ->(n) { n.times { |i| FeatureBench::LimitedJob.perform_async(i) } },
  'concurrent limiter (built per job)' => ->(n) { n.times { |i| FeatureBench::PerJobLimitedJob.perform_async(i) } },
  'status' => ->(n) { n.times { |i| FeatureBench::TrackedJob.perform_async(i) } }
}.freeze

POOL.with { |c| c.call('FLUSHDB') }
measure(10, PUSHES['plain']) # warm: connection prelude, script loads, autoload
PUSHES.each_value { |push| measure(2, push) }

results = PUSHES.transform_values { |push| measure(JOBS, push) }
plain_enqueue, plain_execute = results.fetch('plain')

puts "wurk — #{JOBS} jobs per feature, client-side round trips and commands per job\n\n"
results.each do |name, (enqueue, execute)|
  AlgoBench.print_count("#{name}: enqueue", enqueue, per: JOBS)
  AlgoBench.print_count("#{name}: execute", execute, per: JOBS)
end
puts "\nover the plain job (enqueue + execute):"
BUDGETS.each do |name, budget|
  enqueue, execute = results.fetch(name)
  rt = (enqueue.round_trips + execute.round_trips - plain_enqueue.round_trips - plain_execute.round_trips)
       .fdiv(JOBS).round(2)
  cmds = (enqueue.commands + execute.commands - plain_enqueue.commands - plain_execute.commands).fdiv(JOBS).round(2)
  printf("  %-52s %10s round trips %10s commands\n", name, AlgoBench.num(rt), AlgoBench.num(cmds))
  next unless JOBS == 200

  AlgoBench.budget!("#{name} (round trips/job)", rt, budget[0])
  AlgoBench.budget!("#{name} (commands/job)", cmds, budget[1])
end
POOL.with { |c| c.call('FLUSHDB') }
AlgoBench.finish!
