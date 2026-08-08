# frozen_string_literal: true

require 'logger'
require 'wurk'
require_relative 'support'

# Swarm boot — one of the "Faster" pillar critical paths (CLAUDE.md). Measures
# the REAL fork + reconnect + first-heartbeat latency: each sample boots a small
# swarm from a preloaded parent via the production path (close parent sockets →
# Process.fork → each child reopens its own Redis pool → manager starts) and
# waits until every child has written its :startup marker to Redis. That marker
# is the same race-free, fork-safe "child is up" signal the integration suite
# uses (test/integration/swarm_boot_test.rb).
#
# Reported as boots/second (1 / mean boot latency) so higher = faster, matching
# the i/s convention the bench gate (bin/bench-compare) already understands:
# >5% regression vs main blocks merge. Forking is far too coarse for
# benchmark/ips's tight call loop, so we time K closed samples ourselves and
# print a benchmark/ips-compatible line ("<label>  <ips> (± <err>%) i/s") with
# the measured run-to-run spread as the ±.
#
# Runs on a dedicated Redis logical DB (default 14, mirroring fetch_execute's
# isolated-DB approach from #259) so a stray worker on the default DB can't
# perturb the boot. DB 0 is never touched.

def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

REDIS_URL    = bench_redis_url('14')
CHILDREN     = Integer(ENV.fetch('WURK_BENCH_SWARM_CHILDREN', '2'))
SAMPLES      = Integer(ENV.fetch('WURK_BENCH_SWARM_SAMPLES', '8'))
BOOT_MARKER  = 'wurk-bench:swarm-boot-log'
BOOT_TIMEOUT = 20.0

config = Wurk::Configuration.new
config.logger = Logger.new(IO::NULL)
config.redis = { url: REDIS_URL }
config.queues = %w[default]
config[:timeout] = 1

# Each child RPUSHes its pid the moment it finishes booting (fork + Redis
# reconnect + manager startup). A fresh RedisClient per child — never share a
# socket across forks (CLAUDE.md). Mirrors swarm_boot_test's :startup boot-log.
config.on(:startup) do
  c = RedisClient.config(url: REDIS_URL).new_client
  c.call('RPUSH', BOOT_MARKER, Process.pid.to_s)
  c.call('EXPIRE', BOOT_MARKER, 60)
ensure
  c&.close
end

observer = RedisClient.config(url: REDIS_URL).new_client
topology = Wurk::Topology.flat(count: CHILDREN, queues: %w[default], concurrency: 1)

def wait_for_boot(observer, count) # rubocop:disable Naming/PredicateMethod
  deadline = monotonic + BOOT_TIMEOUT
  while monotonic < deadline
    return true if observer.call('LLEN', BOOT_MARKER).to_i >= count

    sleep 0.005
  end
  false
end

def boot_once(config, topology, observer)
  observer.call('DEL', BOOT_MARKER)
  swarm = Wurk::Swarm.new(topology: topology, config: config, shutdown_timeout: 5)
  t0 = monotonic
  swarm.boot(install_signals: false)
  wait_for_boot(observer, CHILDREN) ? (monotonic - t0) : nil
ensure
  swarm&.shutdown(timeout: 5)
end

# One untimed warmup boot: the first fork pays one-time costs (lazy-loaded
# constants resolving in the children) that would otherwise dominate the spread.
boot_once(config, topology, observer)

latencies = (1..SAMPLES).filter_map { boot_once(config, topology, observer) }

observer.call('DEL', BOOT_MARKER)
observer.close

raise "swarm_boot bench: no children booted within #{BOOT_TIMEOUT}s" if latencies.empty?

mean   = latencies.sum / latencies.size
stddev = Math.sqrt(latencies.sum { |l| (l - mean)**2 } / latencies.size)
ips    = 1.0 / mean
err    = mean.zero? ? 0.0 : (stddev / mean * 100.0)

printf("%-22s %.2f (± %.1f%%) i/s\n", 'wurk swarm boot', ips, err)
