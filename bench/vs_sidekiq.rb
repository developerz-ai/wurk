# frozen_string_literal: true

require 'etc'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'redis-client'
require_relative 'support'

# Wurk vs stock Sidekiq — end-to-end job throughput.
#
# This is the ONLY benchmark in the repo that measures the README's "Faster"
# claim. The others (enqueue, fetch_execute, bulk_enqueue, swarm_boot, memory)
# are a REGRESSION gate: wurk against its own past self via bin/bench-compare.
# They can all be green while wurk is slower than Sidekiq. Pillar 3 of
# CLAUDE.md says "every release benchmarked vs stock Sidekiq" — this is that.
#
#   bin/rake bench:vs_sidekiq
#
# Method, per (workload shape, engine):
#
#   1. FLUSHDB a dedicated Redis logical DB (default 12; DB 0 is never touched).
#   2. RPUSH N identical job payloads straight onto `queue:default` from THIS
#      process. Both engines read the same Redis key schema, so a hand-built
#      payload is the fairest possible starting line — neither side's client
#      code is on the clock, and both dequeue the exact same bytes.
#   3. Start the clock and spawn the real worker binary.
#   4. Poll the completion counter each job INCRs. `boot` is the clock until
#      the first completion; `drain` is first-to-last. Throughput is reported
#      over `drain`, so a slower boot never flatters a slower engine — boot is
#      reported separately instead of hidden inside the rate.
#   5. TERM the workers, repeat. Runs alternate sides tightly so thermal drift
#      and background load hit both engines evenly; the median of RUNS is
#      reported with the observed spread.
#
# The Sidekiq side runs out of bench/vs_sidekiq/Gemfile, NOT the repo bundle —
# see the comment in that file; inside the repo bundle wurk's lib/sidekiq.rb
# shim shadows the real gem and "Sidekiq" would silently be wurk.
#
# Knobs (all optional): WURK_BENCH_VS_JOBS, _CONCURRENCY, _PROCESSES, _RUNS,
# _SHAPES, _CPU_ITERS, _IO_SECONDS, _TIMEOUT, _VERBOSE, and WURK_BENCH_DB.
# With _PROCESSES > 1 the Sidekiq side runs that many independent worker
# processes (what a stock-Sidekiq user actually does — sidekiqswarm is an
# Enterprise feature) and the wurk side runs one wurkswarm forking that many
# children. Same total process count, same threads each.

ROOT            = File.expand_path('..', __dir__)
JOB_FILE        = File.join(ROOT, 'bench', 'vs_sidekiq', 'job.rb')
SIDEKIQ_GEMFILE = File.join(ROOT, 'bench', 'vs_sidekiq', 'Gemfile')
WURK_GEMFILE    = File.join(ROOT, 'Gemfile')
LOG_DIR         = File.join(ROOT, 'tmp')

JOBS        = Integer(ENV.fetch('WURK_BENCH_VS_JOBS', '5000'))
CONCURRENCY = Integer(ENV.fetch('WURK_BENCH_VS_CONCURRENCY', '5'))
PROCESSES   = Integer(ENV.fetch('WURK_BENCH_VS_PROCESSES', '1'))
RUNS        = Integer(ENV.fetch('WURK_BENCH_VS_RUNS', '3'))
SHAPES      = ENV.fetch('WURK_BENCH_VS_SHAPES', 'noop,cpu,io').split(',')
TIMEOUT     = Float(ENV.fetch('WURK_BENCH_VS_TIMEOUT', '180'))
VERBOSE     = !ENV['WURK_BENCH_VS_VERBOSE'].nil?
DONE_KEY    = 'wurk-bench:vs:done'
SIDES       = %i[sidekiq wurk].freeze

unless (unknown_shapes = SHAPES - %w[noop cpu io]).empty?
  raise "bench/vs_sidekiq: unknown shape(s): #{unknown_shapes.join(', ')} (valid: noop, cpu, io)"
end

def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Dedicated logical DB via bench/support.rb (#258/#259) — this bench FLUSHDBs
# between every run, so the never-DB-0 guard in that helper is load-bearing.
REDIS_URL = bench_redis_url('12')

# Every channel `bundle exec` uses to reach into a subprocess, closed. RUBYOPT
# carries `-rbundler/setup`; BUNDLER_SETUP is the same hook by another route
# (rubygems requires it from gem_prelude, so clearing RUBYOPT alone does not
# stop it); GEM_HOME/GEM_PATH pin the child to the PARENT bundle's gem dir, so
# the Sidekiq side resolves against wurk's bundle — where stock sidekiq is not
# installed — and `bundle check`/`install` fail before a single job runs.
# Clearing all of them is what makes BUNDLE_GEMFILE alone decide which
# "sidekiq" the child loads, instead of wurk's shadowing lib/sidekiq.rb.
BUNDLER_LEAKS = %w[RUBYOPT RUBYLIB BUNDLER_SETUP BUNDLER_VERSION BUNDLE_BIN_PATH GEM_HOME GEM_PATH].freeze

def child_env(gemfile, shape, extra = {})
  BUNDLER_LEAKS.to_h { |key| [key, nil] }.merge(
    'BUNDLE_GEMFILE' => gemfile,
    'REDIS_URL' => REDIS_URL,
    'WURK_BENCH_VS_SHAPE' => shape,
    'WURK_BENCH_VS_DONE_KEY' => DONE_KEY
  ).merge(extra)
end

def install_sidekiq_bundle
  env = child_env(SIDEKIQ_GEMFILE, 'noop')
  return if system(env, 'bundle', 'check', chdir: ROOT, out: IO::NULL, err: IO::NULL)

  warn 'installing bench/vs_sidekiq/Gemfile (stock Sidekiq, isolated bundle)...'
  system(env, 'bundle', 'install', chdir: ROOT, out: IO::NULL) ||
    raise('bench/vs_sidekiq: `bundle install` failed for the Sidekiq bundle')
end

# Version of each engine, read from its OWN bundle. Doubles as the proof that
# the isolation works: if this prints the same version twice, the Sidekiq side
# is loading wurk and every number below is meaningless.
def engine_versions
  { sidekiq: engine_version(SIDEKIQ_GEMFILE, 'sidekiq', 'Sidekiq::VERSION'),
    wurk: engine_version(WURK_GEMFILE, 'wurk', 'Wurk::VERSION') }
end

# Argument array + chdir, not a shell string — the checkout path may contain
# spaces, and it stays on the same isolated-bundle path (child_env) as the workers.
def engine_version(gemfile, require_name, const)
  code = %(require "#{require_name}"; print #{const})
  out, = Open3.capture2(
    child_env(gemfile, 'noop'), 'bundle', 'exec', 'ruby', '-e', code,
    chdir: ROOT, err: File::NULL
  )
  out.strip
end

# Hand-built payloads in the shared key schema — the one enqueue path that is
# identical for both engines. Pipelined in slices so seeding stays off the clock.
def enqueue(redis, count)
  now = Time.now.to_f
  (0...count).each_slice(1000) do |slice|
    payloads = slice.map do |_i|
      JSON.generate('class' => 'BenchJob', 'args' => [], 'queue' => 'default',
                    'jid' => SecureRandom.hex(12), 'retry' => false,
                    'created_at' => now, 'enqueued_at' => now)
    end
    redis.call_v(['RPUSH', 'queue:default', *payloads])
  end
  redis.call('SADD', 'queues', 'default')
end

def worker_command(side)
  case side
  when :sidekiq then ['bundle', 'exec', 'sidekiq']
  when :wurk    then ['bundle', 'exec', PROCESSES > 1 ? 'wurkswarm' : 'wurk']
  end
end

# Sidekiq gets PROCESSES independent workers; wurk gets one swarm parent that
# forks PROCESSES children (WURK_COUNT). Same process count, same threads each.
def spawn_workers(side, shape, log)
  gemfile = side == :sidekiq ? SIDEKIQ_GEMFILE : WURK_GEMFILE
  extra = side == :wurk && PROCESSES > 1 ? { 'WURK_COUNT' => PROCESSES.to_s } : {}
  env = child_env(gemfile, shape, extra)
  args = ['-r', JOB_FILE, '-c', CONCURRENCY.to_s, '-q', 'default', '-t', '2']
  redirect = VERBOSE ? {} : { out: log, err: log }
  count = side == :sidekiq ? PROCESSES : 1
  pids = []
  count.times { pids << Process.spawn(env, *worker_command(side), *args, chdir: ROOT, **redirect) }
  pids
rescue StandardError
  stop_workers(pids)
  raise
end

def stop_workers(pids)
  pids.each { |pid| Process.kill('TERM', pid) rescue nil } # rubocop:disable Style/RescueModifier
  deadline = monotonic + 20
  pids.each do |pid|
    until Process.waitpid(pid, Process::WNOHANG)
      break Process.kill('KILL', pid) if monotonic > deadline

      sleep 0.01
    end
    Process.waitpid(pid) rescue nil # rubocop:disable Style/RescueModifier
  end
end

# Returns [boot_seconds, drain_seconds]. Boot is spawn -> first completion;
# drain is first -> last, and throughput is reported over drain alone.
def measure(redis, log, start:)
  first = nil
  loop do
    done = redis.call('GET', DONE_KEY).to_i
    (first ||= monotonic) if done.positive?
    return [first - start, [monotonic - first, 1e-6].max] if done >= JOBS
    raise_timeout(log, done) if monotonic - start > TIMEOUT

    sleep 0.002
  end
end

def raise_timeout(log, done)
  tail = File.exist?(log) ? File.readlines(log).last(20).join : '(no worker output)'
  raise "bench/vs_sidekiq: only #{done}/#{JOBS} jobs finished in #{TIMEOUT}s.\n#{tail}"
end

def one_run(redis, side, shape)
  redis.call('FLUSHDB')
  enqueue(redis, JOBS)
  log = File.join(LOG_DIR, "vs_sidekiq-#{side}-#{shape}.log")
  start = monotonic
  pids = spawn_workers(side, shape, log)
  boot, drain = measure(redis, log, start: start)
  [boot, JOBS / drain]
ensure
  stop_workers(pids) if pids
end

def median(values)
  sorted = values.sort
  mid = sorted.size / 2
  sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def spread_pct(values)
  return 0.0 if values.size < 2

  mid = median(values)
  mid.zero? ? 0.0 : (values.max - values.min) / mid * 100.0
end

def report(throughput, boots, versions)
  puts
  puts "| workload | Sidekiq #{versions[:sidekiq]} | Wurk #{versions[:wurk]} | speedup |"
  puts '|---|---|---|---|'
  SHAPES.each do |shape|
    sk = median(throughput[[shape, :sidekiq]])
    wk = median(throughput[[shape, :wurk]])
    puts format('| %-4s | %s jobs/s | %s jobs/s | **%.2fx** |', shape,
                format('%.0f (±%.0f%%)', sk, spread_pct(throughput[[shape, :sidekiq]])),
                format('%.0f (±%.0f%%)', wk, spread_pct(throughput[[shape, :wurk]])), wk / sk)
  end
  puts
  SIDES.each do |side|
    boot = median(SHAPES.flat_map { |shape| boots[[shape, side]] })
    puts format('boot to first job — %-7s %.2fs', side, boot)
  end
end

def preamble(versions)
  cores = Etc.nprocessors
  puts "wurk #{versions[:wurk]} vs sidekiq #{versions[:sidekiq]} — ruby #{RUBY_VERSION} " \
       "(#{RUBY_PLATFORM}), #{cores} cores"
  puts "#{JOBS} jobs/run · #{PROCESSES} process(es) x #{CONCURRENCY} threads · " \
       "#{RUNS} runs (median) · #{REDIS_URL}"
  puts "shapes: #{SHAPES.join(', ')} (cpu=#{ENV.fetch('WURK_BENCH_VS_CPU_ITERS', '20000')} iters, " \
       "io=#{ENV.fetch('WURK_BENCH_VS_IO_SECONDS', '0.005')}s sleep)"
end

install_sidekiq_bundle
FileUtils.mkdir_p(LOG_DIR)
versions = engine_versions
raise 'bench/vs_sidekiq: could not resolve engine versions' if versions.values.any?(&:empty?)

preamble(versions)

redis = RedisClient.config(url: REDIS_URL).new_client
throughput = Hash.new { |h, k| h[k] = [] }
boots = Hash.new { |h, k| h[k] = [] }

RUNS.times do |run|
  SHAPES.each do |shape|
    SIDES.each do |side|
      boot, rate = one_run(redis, side, shape)
      throughput[[shape, side]] << rate
      boots[[shape, side]] << boot
      warn format('  run %d/%d %-4s %-7s %8.0f jobs/s (boot %.2fs)', run + 1, RUNS, shape, side, rate, boot)
    end
  end
end

redis.call('FLUSHDB')
redis.close
report(throughput, boots, versions)
