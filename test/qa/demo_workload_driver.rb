# frozen_string_literal: true

# Behavioral driver for #33 — the demo workload generator.
#
# Boots a REAL in-process Wurk worker (embedded mode: full middleware chain,
# scheduled + cron pollers, metrics rollup) on an isolated Redis DB, runs the
# Demo::Workload generator, and polls every dashboard surface until each shows
# non-trivial values — proving the issue's "Done when": every widget has signal
# within ~30s of a cold start. Prints PASS/FAIL and cleans up.
#
#   ruby test/qa/demo_workload_driver.rb
#
# Needs a local Redis (uses DB 15 so it never touches your real data).

require 'pathname'
ROOT = Pathname.new(__dir__).join('..', '..').expand_path
$LOAD_PATH.unshift(ROOT.join('lib').to_s)
require 'wurk'
require 'logger'

DEMO_APP = ROOT.join('test', 'dummy', 'app')
Dir[DEMO_APP.join('jobs', 'demo', '*.rb').to_s].each { |f| require f }
require DEMO_APP.join('workloads', 'demo', 'workload.rb').to_s

URL = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0').sub(%r{/\d+\z}, '/15')
DEADLINE = Integer(ENV.fetch('WURK_DEMO_DEADLINE', '30')) # seconds

# --- isolated config + worker ------------------------------------------------
config = Wurk.configuration
config.logger = Logger.new(IO::NULL)
config.redis = { url: URL }
config.queues = %w[default high low]
config.concurrency = 5
config[:cron_tick_interval]       = 0.5 # fire cron promptly within the window
config[:scheduled_poll_interval]  = 0.5 # promote retries quickly
config[:leader_ttl]               = 3
config[:leader_renew_interval]    = 0.5
config[:leader_follower_interval] = 0.5

Wurk.redis { |c| c.call('FLUSHDB') }

# Record per-job history so the throughput/failures charts have data (the
# History middleware is opt-in; the demo turns it on — see the demo initializer).
config.server_middleware.add(Wurk::Metrics::History)

worker = Wurk.configure_embed { |c| c.concurrency = 5 }
worker.run

workload = Demo::Workload.new
generator = Thread.new do
  loop do
    workload.tick!
    sleep 0.4
  rescue StandardError
    sleep 0.4
  end
end

# --- widget probes -----------------------------------------------------------
def scan?(match)
  cursor = '0'
  loop do
    cursor, keys = Wurk.redis { |c| c.call('SCAN', cursor, 'MATCH', match, 'COUNT', 200) }
    return true unless keys.empty?
    break if cursor == '0'
  end
  false
end

PROBES = {
  'Dashboard: processed > 0' => -> { Wurk::Stats.new.processed.to_i.positive? },
  'Dashboard: failed > 0' => -> { Wurk::Stats.new.failed.to_i.positive? },
  'Queues: jobs enqueued' => -> { %w[default high low].sum { |q| Wurk::Queue.new(q).size }.positive? },
  'Queues: >1 queue active' => -> { %w[default high low].count { |q| Wurk::Queue.new(q).size.positive? } > 1 },
  'Scheduled: non-empty' => -> { Wurk::ScheduledSet.new.size.positive? },
  'Retries: non-empty' => -> { Wurk::RetrySet.new.size.positive? },
  'Dead: non-empty' => -> { Wurk::DeadSet.new.size.positive? },
  'Batches: non-empty' => -> { Wurk::BatchSet.new.size.positive? },
  'Limiters: demo-emails' => -> { Wurk.redis { |c| c.call('SISMEMBER', 'lmtr-list', 'demo-emails') } == 1 },
  'Limiters: demo-api' => -> { Wurk.redis { |c| c.call('SISMEMBER', 'lmtr-list', 'demo-api') } == 1 },
  'Cron: loops registered' => -> { Wurk::Cron::LoopSet.new.to_a.size >= 2 },
  'Metrics: per-class buckets' => -> { scan?('j|*') }
}.freeze

results = {}
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
loop do
  PROBES.each do |label, probe|
    results[label] ||= begin
      (probe.call ? true : nil)
    rescue StandardError
      nil
    end
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  break if (results.size == PROBES.size && results.values.all?) || elapsed > DEADLINE

  sleep 0.5
end
elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

# Best-effort signals that depend on a clock boundary within the window.
info = {
  'Cron: fired at least once' => -> { Wurk::Cron::LoopSet.new.to_a.any?(&:last_fired_at) },
  'Throughput chart (jr| rollup buckets)' => -> { scan?('jr|*') }
}

# --- teardown ----------------------------------------------------------------
generator.kill
worker.stop

# --- report ------------------------------------------------------------------
puts "\n#33 demo workload — every dashboard widget within #{DEADLINE}s (took #{elapsed}s)\n\n"
failures = 0
PROBES.each_key do |label|
  ok = results[label]
  failures += 1 unless ok
  puts "  #{ok ? '✅ PASS' : '❌ FAIL'}  #{label}"
end
puts "\n  (informational — depend on a minute boundary in-window)"
info.each { |label, probe| puts "  #{probe.call ? '•' : '◦'}  #{label}" }

Wurk.redis { |c| c.call('FLUSHDB') }

if failures.zero?
  puts "\nALL PASS — demo is dashboard-ready."
  exit 0
else
  puts "\n#{failures} FAILED"
  exit 1
end
