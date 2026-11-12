# frozen_string_literal: true

require 'logger'
require 'wurk'
require_relative 'support'

# Per-job Redis command tripwire — the round-trip half of the "Why wurk is
# slower" story in docs/benchmarks.md — followed by a per-heartbeat one
# (docs/benchmarks.md, "Commands per heartbeat"). Scripts the `INFO commandstats` method
# that table was measured with: drain JOBS pre-enqueued noop jobs through the
# REAL reliable fetcher and Processor#process_one, then read the server's own
# per-command call counters and divide by jobs.
#
# NOT part of `rake bench`. The gate feeds its output to bin/bench-compare,
# which only parses benchmark/ips report lines; this prints a command table and
# asserts a budget. It is excluded from GATE_SCRIPTS in the Rakefile alongside
# vs_sidekiq.rb — run it on its own via `rake bench:command_count`, which
# bench.yml's `commands per job` job does on every PR touching a bench input.
#
# Counts COMMANDS, not round trips — `INFO commandstats` cannot see a pipeline.
# The ack piggyback has landed, so those 3 commands now cost one round trip
# rather than three (Fetcher::Reliable pipelines the finished job's LREM + DEL
# in front of the next job's LMOVE), but the count is unmoved and the budget is
# counted in commands.
#
# The budget is re-baselined to 3, the settled floor for this command shape —
# down from ~10 (docs/benchmarks.md, "Why wurk is slower") before this PR group.
# The one candidate to lose was the poison-pill DEL, meaningful only for a job the
# reaper reclaimed — step 4 of
# docs/plans/2026/08/06/101-faster-than-sidekiq/02-fetch-ack-metrics.md, now
# settled: it stays. A reclaimed payload is byte-identical to a first-attempt
# one (the job JSON is wire-frozen), so only the counter knows, and reading it
# to decide costs more than the DEL rides for. Nor can Lua hide the other two:
# `INFO commandstats` counts a script's own calls as well as the EVALSHA, so
# folding LREM + DEL + LMOVE into one script would read as 4 here, not 1. Those
# 3 commands cost one round trip between them (down from 4 before this PR
# group), which is the number that actually drives throughput — see
# `bench:fetch_execute` and docs/benchmarks.md, "Status".
#
# Two costs that used to show here are already gone: an SMEMBERS of the paused
# set per fetch pass (Fetcher::Reliable now reads that SET once per PAUSED_TTL)
# and the Metrics::History writes per job (Metrics::Accumulator folds them in
# memory; Metrics::Flusher drains them every FLUSH_INTERVAL).
#
# Those metrics writes are ZERO here, not amortized: this loop runs no Launcher,
# so no flusher ticks inside the window. A real worker pays one pipeline of
# eight commands (ten with failures) per (class, minute) every 5 seconds no
# matter its throughput, which rounds to nothing per job at any rate this bench would measure — but the
# table below is a per-job budget, and that cost is not in it.
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

JOBS   = Integer(ENV.fetch('WURK_BENCH_CMD_JOBS', '500'))
BUDGET = Float(ENV.fetch('WURK_BENCH_CMD_BUDGET', '3'))
# The floor, checked as strictly as the ceiling. A count that DROPS is a win,
# but an unannounced one leaves the comment above, docs/benchmarks.md and the
# plan all quoting a number no run reproduces — the failure mode this script
# exists to prevent, in the direction a budget alone can't see. Landing a
# reduction means re-baselining here and republishing the prose in the same
# commit, which is the point.
BASELINE = Float(ENV.fetch('WURK_BENCH_CMD_BASELINE', '3'))

# This same BUDGET/BASELINE pair (env-overridable, not forked into new
# constants) IS the "feature disabled" gate that three slices of
# docs/plans/2026/08/07/101-beyond-sidekiq/overview.md are written against —
# each ships nothing on the default enqueue/fetch/execute path, so its "off"
# state is, until it lands, indistinguishable from today's run of this script:
#
#   06 job status/results  — an untracked worker (no `track:` opt-in) must add
#                             zero commands here (06-job-status-results.md).
#   09 debounce/throttle   — a worker with no unique policy set must add zero
#                             commands here (09-debounce-throttle.md).
#   10 global concurrency  — a queue with no cap configured must add zero
#                             commands here (10-global-concurrency.md); the one
#                             slice allowed to close as "deferred" if it can't.
#
# Rake exposes each as its own name (`rake bench:command_count_tracked_off`,
# `:command_count_policy_off`, `:command_count_cap_off`, see Rakefile) so each
# slice's PR gets a pre-existing, reviewable CI target instead of inventing
# one under review — and so a regression that only shows up once one of these
# features exists still reads as "the tracked/policy/cap-off gate failed",
# not a mystery command-count drift.
WARMUP = [JOBS / 10, 1].max

# Per-beat heartbeat counts (plan 101/06 P6), held exactly in both directions
# like the per-job pair above: a beat is a fixed command shape, so any drift is
# a change to that shape. `plain` is an idle process with no statsd client,
# leader or not. With `config.dogstatsd` set, every process GETs the leader
# lock and gauges `busy`, and only the leader LLENs each of its queues for
# `queue.size` (one queue here).
PLAIN_BEAT = Float(ENV.fetch('WURK_BENCH_CMD_PLAIN_BEAT', '5'))
FOLLOWER_BEAT = Float(ENV.fetch('WURK_BENCH_CMD_FOLLOWER_BEAT', '6'))
LEADER_BEAT = Float(ENV.fetch('WURK_BENCH_CMD_LEADER_BEAT', '7'))
BEATS = 10

# Redis records CONFIG RESETSTAT *after* it clears the counters, so the reset
# that opens the window shows up inside it. INFO needs no such treatment: it
# reports the counters as they stood before it ran, so it never counts itself.
HARNESS_COMMANDS = %w[config|resetstat].freeze

# Connection upkeep, not job work: redis-client PINGs a connection that sat
# idle past `idle_timeout` before reusing it (RedisClient#raw_connection), and a
# reconnect re-sends its handshake. Whether one lands inside the window is
# timing — a single stray PING once read as 3.002 commands/job and failed the
# budget. They are printed below the table, never counted per job.
CONNECTION_COMMANDS = %w[ping hello auth select client|setname client|setinfo].freeze

class BenchJob
  include Wurk::Job

  def perform(*); end
end

# Swallows gauges: the heartbeat's statsd branch runs, nothing is sent.
NULL_STATSD = Class.new { def gauge(*, **); end }.new

# Server-side call counters, keyed by command name ("hincrby", "config|get").
def command_calls(capsule)
  info = capsule.redis { |c| c.call('INFO', 'commandstats') }
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

def report(calls, jobs, unit = 'job')
  upkeep, work = calls.partition { |cmd, _| CONNECTION_COMMANDS.include?(cmd) }
  work.sort_by { |_, count| -count }.each { |cmd, count| printf("  %8d  %7.2f  %s\n", count, count / jobs.to_f, cmd) }
  puts '  --------  -------'
  total = work.sum { |_, count| count }
  printf("  %8d  %7.2f  total\n\n", total, total / jobs.to_f)
  upkeep.each { |cmd, count| printf("  (not per #{unit}: %d %s, connection upkeep)\n", count, cmd) }
  puts unless upkeep.empty?
  total / jobs.to_f
end

# The process-global config, not a fresh Wurk::Configuration.new: the default
# server middleware chain is registered onto this one at load (wurk.rb:297-312),
# and a fresh Configuration starts with an EMPTY chain — so benching against one
# would drop the whole middleware stack out of the measurement and report a
# number no worker can reproduce. Every real worker boots from this object.
config = Wurk.configuration
config.logger = Logger.new(IO::NULL)
config.redis = { url: bench_redis_url('9') }
config.queues = %w[default]
capsule = config.default_capsule
capsule.prepare!

# Isolated scratch DB: a clean slate keeps this closed loop the only consumer
# of queue:default, so every fetch finds the job we pushed.
capsule.redis { |c| c.call('FLUSHDB') }
capsule.redis { |c| Wurk::Lua::Loader.script_load_all(c) }

client    = Wurk::Client.new(pool: capsule.redis_pool)
processor = Wurk::Processor.new(capsule)

client.push_bulk('class' => 'BenchJob', 'args' => Array.new(WARMUP + JOBS) { [] }, 'queue' => 'default')
drain(processor, WARMUP)

capsule.redis { |c| c.call('CONFIG', 'RESETSTAT') }
processed = drain(processor, JOBS)
calls     = command_calls(capsule)

capsule.redis { |c| c.call('FLUSHDB') }

# A queue that ran dry parks the fetcher in BLMOVE and yields nil: fewer
# commands for fewer jobs, which reads as an improvement. Fail loud instead.
unless processed == JOBS
  abort format('✗ drained %d of %d jobs — the queue ran dry, so the count is meaningless', processed, JOBS)
end

puts "wurk — #{JOBS} noop jobs drained from queue:default (INFO commandstats)\n\n"
puts '  commands  per job  command'
per_job = report(calls, JOBS)
# abort writes to unbuffered stderr, which would land the verdict above the
# table it is a verdict on.
$stdout.flush

abort format('✗ %.2f commands/job, over the budget of %.2f', per_job, BUDGET) if per_job > BUDGET
if per_job < BASELINE
  abort format(
    '✗ %.2f commands/job, under the recorded baseline of %.2f — re-baseline this script and republish ' \
    'docs/benchmarks.md from this run',
    per_job, BASELINE
  )
end
puts format('✓ %.2f commands/job, within the budget of %.2f and at the recorded baseline of %.2f',
            per_job, BUDGET, BASELINE)

puts

# A fresh Heartbeat per beat, so its leader? cache starts cold on each one —
# as on every real beat, because BEAT_PAUSE (10s) outlasts
# Component::LEADER_CACHE_TTL_MS (5s). The leader lock is planted, not won:
# only the GET that reads it is under test.
def beats(capsule, config, leader:)
  identity = "bench-heartbeat:#{Process.pid}"
  capsule.redis { |c| c.call('SET', Wurk::Leader::DEFAULT_KEY, leader ? identity : 'someone-else') }
  Wurk::Heartbeat.new(identity:, config:).beat! # first-beat registration off the clock
  capsule.redis { |c| c.call('CONFIG', 'RESETSTAT') }
  BEATS.times { Wurk::Heartbeat.new(identity:, config:).beat! || abort('✗ a heartbeat failed') }
  command_calls(capsule)
end

beat_failures = []
{ 'plain' => [PLAIN_BEAT, nil, false],
  'statsd follower' => [FOLLOWER_BEAT, -> { NULL_STATSD }, false],
  'statsd leader' => [LEADER_BEAT, -> { NULL_STATSD }, true] }.each do |name, (baseline, statsd, leader)|
  config.dogstatsd = statsd
  calls = beats(capsule, config, leader:)
  puts "wurk — #{BEATS} idle heartbeats, #{name} (INFO commandstats)\n\n"
  puts '  commands  per beat  command'
  per_beat = report(calls, BEATS, 'beat')
  beat_failures << format('%s: %.2f commands/beat, recorded %.2f', name, per_beat, baseline) if per_beat != baseline
end
config.dogstatsd = nil
capsule.redis { |c| c.call('FLUSHDB') }
$stdout.flush

unless beat_failures.empty?
  abort "✗ heartbeat command count moved — re-baseline bench/command_count.rb and docs/benchmarks.md together:\n  " \
        "#{beat_failures.join("\n  ")}"
end
puts format('✓ %.0f / %.0f / %.0f commands per beat (plain / statsd follower / statsd leader), at the baseline',
            PLAIN_BEAT, FOLLOWER_BEAT, LEADER_BEAT)
