# frozen_string_literal: true

require "logger"
require "wurk"
require_relative "support"

# Per-job Redis command tripwire — the round-trip half of the "Why wurk is
# slower" story in docs/benchmarks.md. Scripts the `INFO commandstats` method
# that table was measured with: drain JOBS pre-enqueued noop jobs through the
# REAL reliable fetcher and Processor#process_one, then read the server's own
# per-command call counters and divide by jobs.
#
# NOT part of `rake bench`. The gate feeds its output to bin/bench-compare,
# which only parses benchmark/ips report lines; this prints a command table and
# asserts a budget. It is excluded from GATE_SCRIPTS in the Rakefile alongside
# vs_sidekiq.rb — run it on its own via `rake bench:command_count`.
#
# EXPECTED TO FAIL until the fetch/ack/metrics batching lands: steady state
# today is 10 commands per job against a budget of 2 — 6 unbatched
# Metrics::History writes (4 HINCRBY + 2 EXPIRE, one pair per time bucket),
# LMOVE + LREM + DEL for reliable fetch, ack and poison-pill retire, and one
# SMEMBERS of the paused set per fetch. That red is the tripwire naming the
# work, not a broken bench. (docs/benchmarks.md quotes ~12 from a hand-run of
# the same method; the printed breakdown below is the reproducible count.)
#
# Only the drain is counted. Enqueue happens before CONFIG RESETSTAT — it is
# the client's cost and enqueue.rb already benches it — and a warmup pass runs
# first so no one-time cost (the fetch pool's connection handshake, the EVALSHA
# cache, autoload) lands inside the window.
#
# `INFO commandstats` is server-wide, not per-DB, so this wants an otherwise
# idle Redis. Foreign traffic inflates the count and shows up as commands the
# job path never issues — read the breakdown, not just the total. The failure
# mode is a false alarm, never a silent pass.
#
# Runs on a dedicated logical DB (default 9, unused by the other benches) so a
# stray dev/CI Redis with real data is never drained or flushed. DB 0 is never
# touched.

JOBS   = Integer(ENV.fetch("WURK_BENCH_CMD_JOBS", "500"))
BUDGET = Float(ENV.fetch("WURK_BENCH_CMD_BUDGET", "2"))
WARMUP = [JOBS / 10, 1].max

# Redis records CONFIG RESETSTAT *after* it clears the counters, so the reset
# that opens the window shows up inside it. INFO needs no such treatment: it
# reports the counters as they stood before it ran, so it never counts itself.
HARNESS_COMMANDS = %w[config|resetstat].freeze

class BenchJob
  include Wurk::Job

  def perform(*); end
end

# Server-side call counters, keyed by command name ("hincrby", "config|get").
def command_calls(capsule)
  info = capsule.redis { |c| c.call("INFO", "commandstats") }
  info.each_line
      .filter_map { |line| line.match(/\Acmdstat_(?<cmd>[^:]+):calls=(?<calls>\d+)/) }
      .to_h { |m| [m[:cmd], Integer(m[:calls])] }
      .except(*HARNESS_COMMANDS)
end

# Returns how many jobs actually ran: process_one answers nil both for "job
# done" and "queue was empty", so the counter is the only honest witness.
def drain(processor, jobs)
  Wurk::Processor::PROCESSED.reset
  jobs.times { processor.process_one }
  Wurk::Processor::PROCESSED.reset
end

def report(calls, jobs)
  rows = calls.sort_by { |_, count| -count }
  rows.each { |cmd, count| printf("  %8d  %7.2f  %s\n", count, count / jobs.to_f, cmd) }
  puts "  --------  -------"
  total = calls.values.sum
  printf("  %8d  %7.2f  total\n\n", total, total / jobs.to_f)
  total / jobs.to_f
end

# The process-global config, not a fresh Wurk::Configuration.new: the default
# server middleware chain is registered onto this one at load (wurk.rb:297-312)
# and 6 of today's 10 commands per job are Metrics::History writes from it. A
# fresh Configuration starts with an EMPTY chain, so benching against one would
# hide exactly the writes this tripwire exists to watch. Every real worker boots
# from this object.
config = Wurk.configuration
config.logger = Logger.new(IO::NULL)
config.redis = { url: bench_redis_url("9") }
config.queues = %w[default]
capsule = config.default_capsule
capsule.prepare!

# Isolated scratch DB: a clean slate keeps this closed loop the only consumer
# of queue:default, so every fetch finds the job we pushed.
capsule.redis { |c| c.call("FLUSHDB") }
capsule.redis { |c| Wurk::Lua::Loader.script_load_all(c) }

client    = Wurk::Client.new(pool: capsule.redis_pool)
processor = Wurk::Processor.new(capsule)

client.push_bulk("class" => "BenchJob", "args" => Array.new(WARMUP + JOBS) { [] }, "queue" => "default")
drain(processor, WARMUP)

capsule.redis { |c| c.call("CONFIG", "RESETSTAT") }
processed = drain(processor, JOBS)
calls     = command_calls(capsule)

capsule.redis { |c| c.call("FLUSHDB") }

# A queue that ran dry parks the fetcher in BLMOVE and yields nil: fewer
# commands for fewer jobs, which reads as an improvement. Fail loud instead.
unless processed == JOBS
  abort format("✗ drained %d of %d jobs — the queue ran dry, so the count is meaningless", processed, JOBS)
end

puts "wurk — #{JOBS} noop jobs drained from queue:default (INFO commandstats)\n\n"
puts "  commands  per job  command"
per_job = report(calls, JOBS)
# abort writes to unbuffered stderr, which would land the verdict above the
# table it is a verdict on.
$stdout.flush

abort format("✗ %.2f commands/job, over the budget of %.2f", per_job, BUDGET) if per_job > BUDGET
puts format("✓ %.2f commands/job, within the budget of %.2f", per_job, BUDGET)
