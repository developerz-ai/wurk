# frozen_string_literal: true

# Bounded showcase check for the PUBLIC demo (demo/ app, DemoProducer).
#
# Boots a real embedded Wurk worker (full middleware chain, scheduled + cron
# pollers, metrics History) plus the demo/ producer against a scratch Redis DB,
# runs for RUN_SECONDS, then prints a per-tab report (one line per dashboard
# surface) and exits non-zero if any showcase-critical surface is empty. Unlike
# test/qa/demo_live_preview.rb this is one-shot — it does not linger as a server.
#
#   ruby test/qa/demo_showcase_check.rb
#   RUN_SECONDS=45 ruby test/qa/demo_showcase_check.rb   # longer soak
#
# Verifies #135: every tab demos well at the #133 light-load cadence.

require 'pathname'
require 'uri'
ROOT = Pathname.new(__dir__).join('..', '..').expand_path
$LOAD_PATH.unshift(ROOT.join('lib').to_s)
require 'wurk'
require 'logger'

# Load the *deployed* demo's job classes + producer (plain Sidekiq::Job, no Rails).
JOBS = ROOT.join('demo', 'app', 'jobs')
Dir[JOBS.join('*.rb').to_s].each { |f| require f }
require ROOT.join('demo', 'app', 'workloads', 'demo_producer.rb').to_s

URL = ENV.fetch('REDIS_URL', 'redis://localhost:6379/15').sub(%r{/\d+\z}, '/15')

# This harness FLUSHDBs its scratch DB (15) at start and on exit. Refuse to do
# that against a non-local host unless the caller explicitly opts in, so a stray
# REDIS_URL can never wipe a shared/remote instance's DB 15.
unless %w[localhost 127.0.0.1 ::1].include?(URI(URL).host) || ENV['ALLOW_FLUSHDB'] == '1'
  abort "Refusing to FLUSHDB #{URL} — this harness flushes its scratch DB. " \
        "Point it at a local Redis, or set ALLOW_FLUSHDB=1 to override."
end

RUN_SECONDS = Float(ENV.fetch('RUN_SECONDS', '30'))
TICK = 2.0 # faster than prod's 10s so the check fills up quickly

config = Wurk.configuration
config.logger = Logger.new(IO::NULL)
config.redis = { url: URL }
config.queues = %w[default high low]
config.concurrency = 5
config[:cron_tick_interval]      = 1.0
config[:scheduled_poll_interval] = 1.0
config[:leader_ttl]              = 3
config[:leader_renew_interval]   = 0.5

Wurk.redis { |c| c.call('FLUSHDB') }
config.server_middleware.add(Wurk::Metrics::History)

worker = Wurk.configure_embed { |c| c.concurrency = 5 }
worker.run

producer = DemoProducer.new(interval: TICK)

stop = false
%w[INT TERM].each { |sig| trap(sig) { stop = true } }

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
$stderr.puts "showcase check → #{URL}, running #{RUN_SECONDS.to_i}s…"
until stop || (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) >= RUN_SECONDS
  begin
    producer.tick!
  rescue StandardError => e
    $stderr.puts "  tick error (continuing): #{e.class}: #{e.message}"
  end
  (TICK * 2).to_i.times { break if stop; sleep 0.5 }
end

# ── Gather every surface the dashboard tabs read ──────────────────────────────
def safe(default = 0)
  yield
rescue StandardError => e
  $stderr.puts "  (probe error: #{e.class}: #{e.message})"
  default
end

stats   = Wurk::Stats.new
queues  = safe([]) { Wurk::Queue.all.map { |q| [q.name, q.size] } }
results = [
  ['Dashboard/Metrics — processed', safe { stats.processed.to_i },                       :gt0],
  ['Dashboard/Metrics — failed',    safe { stats.failed.to_i },                          :gt0],
  ['Queues — distinct queues',      queues.size,                                         :gt0],
  ['Queues — total enqueued',       queues.sum { |(_, n)| n },                           :any],
  ['Scheduled',                     safe { Wurk::ScheduledSet.new.size },                :gt0],
  ['Retries',                       safe { Wurk::RetrySet.new.size },                    :gt0],
  ['Dead',                          safe { Wurk::DeadSet.new.size },                     :gt0],
  ['Busy — processes',             safe { Wurk::ProcessSet.new.size },                   :gt0],
  ['Batches',                       safe { Wurk::BatchSet.new.size },                    :gt0],
  ['Limiters',                      safe { Wurk::Web::Enterprise::Limits.list.size },    :gt0],
  ['Cron — loops',                  safe { Wurk::Cron::LoopSet.new.to_a.size },          :gt0],
  ['Metrics — top jobs (60m)',      safe { Wurk::Web::Enterprise::Historical.top(minutes: 60).size }, :gt0],
  ['Metrics — history series (1m)', safe { Wurk::Web::Enterprise::Historical.history('1m', window: 3600).size }, :warn]
]

worker.stop
Wurk.redis { |c| c.call('FLUSHDB') }

# ── Report ────────────────────────────────────────────────────────────────────
puts "\n  per-tab showcase report (demo/ producer, #{RUN_SECONDS.to_i}s soak)"
puts '  ' + ('─' * 56)
failures = 0
results.each do |label, value, rule|
  ok =
    case rule
    when :gt0  then value.to_i.positive?
    when :any  then true
    when :warn then true
    end
  mark = if rule == :warn && !value.to_i.positive?
           '⚠ '
         elsif ok
           '✓ '
         else
           failures += 1
           '✗ '
         end
  puts format('  %s%-32s %s', mark, label, value)
end
puts '  ' + ('─' * 56)
if failures.zero?
  puts '  PASS — every showcase-critical tab has data.'
  exit 0
else
  puts "  FAIL — #{failures} surface(s) empty; tune the producer."
  exit 1
end
