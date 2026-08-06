# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  require "simplecov-cobertura"
  SimpleCov.start do
    # Both line and branch coverage on lib/ are blocking gates (>= 90%). The
    # Cobertura report is still uploaded by CI for per-file inspection. Branch
    # was ratcheted from ~78% to >=90% in #67; keep new code at parity.
    enable_coverage :branch
    primary_coverage :line
    add_filter "/test/"
    add_filter "/bench/"
    minimum_coverage line: 90, branch: 90
    formatter SimpleCov::Formatter::CoberturaFormatter
  end
end

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

# --- Per-worker Redis DB isolation -----------------------------------------
# Tests must never touch the base Redis DB (0): teardown runs FLUSHDB, which
# would wipe a developer's real data. Each minitest-parallel_fork worker instead
# gets its own logical DB (Redis ships 16; we use 1..15) so concurrent test
# classes never see each other's keys. The baseline below (DB 1) covers the
# parent / serial (un-forked) run; after_parallel_fork bumps each worker to its
# own DB. Tests that build a pool explicitly should use `Wurk::Test.redis_url`.
module Wurk
  module Test
    # Redis ships 16 logical DBs (0..15). DB 0 is never used (teardown FLUSHDB
    # would wipe a developer's real data). Parallel workers take 1..14; DB 15 is
    # reserved for tests that need a private fixed DB and touch un-prefixable
    # global keys (see DemoWorkloadTest), so a worker is never assigned the same
    # DB such a test flushes.
    REDIS_DATABASES = 15
    WORKER_DATABASES = REDIS_DATABASES - 1 # 14 → DBs 1..14 for parallel workers
    DEDICATED_DB = REDIS_DATABASES         # 15 → fixed-DB tests only

    class << self
      attr_accessor :redis_url

      def redis_url_for_db(database)
        base = ENV["REDIS_URL"] || "redis://localhost:6379/0"
        base.match?(%r{/\d+\z}) ? base.sub(%r{/\d+\z}, "/#{database}") : "#{base}/#{database}"
      end

      # Point this process at its own DB. Updates ENV so fresh Configurations and
      # RedisPools pick it up, and caches the URL for explicit-pool tests.
      #
      # No modulo wrap: a `worker_index % WORKER_DATABASES` would silently map
      # worker N back onto worker 0's DB, and that worker's startup FLUSHDB then
      # wipes worker 0's keys mid-test (the #84/#73 flake class). The worker count
      # is capped to WORKER_DATABASES below, so this raises only if that cap is
      # ever bypassed — loud beats silent cross-contamination.
      def assign_redis_db(worker_index)
        if worker_index >= WORKER_DATABASES
          raise "test worker #{worker_index} has no isolated Redis DB " \
                "(only #{WORKER_DATABASES} for parallel workers); cap NCPU at #{WORKER_DATABASES}"
        end

        self.redis_url = redis_url_for_db(worker_index + 1)
        ENV["REDIS_URL"] = redis_url
      end
    end
  end
end

Wurk::Test.assign_redis_db(0) # serial/parent baseline (DB 1), before Wurk loads

require "wurk"

# Silence the global configuration's logger so default ERROR_HANDLER doesn't
# spam test output. Per-test logger overrides still work — they assign a
# StringIO/NULL logger on a fresh Wurk::Configuration.
Wurk.configuration.logger = Logger.new(IO::NULL)

require "minitest/autorun"

# minitest-parallel_fork forks ENV["NCPU"] workers (default 4) — and it forks
# that many regardless of how many suites there are, so idle extra workers run
# their startup FLUSHDB too. Each worker is isolated on its own Redis logical DB
# (1..14; never 0, and 15 is reserved). More workers than DBs would collide and
# a colliding worker's FLUSHDB would wipe a peer's keys mid-test — the root cause
# of the #84 batch-TTL and #73 periodic-leader flakes. Cap the worker count to
# the number of worker DBs so every worker gets a unique one. (CI leaves NCPU
# unset → 4, so this is a no-op there; it only bites machines that set a high
# NCPU for speed.)
ENV["NCPU"] = Wurk::Test::WORKER_DATABASES.to_s if (ENV["NCPU"] || "4").to_i > Wurk::Test::WORKER_DATABASES

require "minitest/parallel_fork" rescue nil

# minitest-parallel_fork runs each test class in a forked worker, so the
# parent's SimpleCov (started above) sees almost no execution — a naive
# coverage run reports ~1%. Re-init SimpleCov inside each worker with a unique
# command name (SimpleCov.at_fork) so every worker writes its own resultset;
# the parent then merges them all. Process.waitall before the parent's at-exit
# merge guarantees every worker has finished writing first. Hooking the gem's
# own fork callback (not Process._fork) leaves the swarm's real forks alone.
# Each forked worker gets its own Redis DB (isolation) and, under COVERAGE, its
# own SimpleCov resultset. parallel_fork keeps a single after_parallel_fork
# block, so both concerns share one hook.
if Minitest.respond_to?(:after_parallel_fork)
  Minitest.after_parallel_fork do |worker|
    Wurk::Test.assign_redis_db(worker)
    Wurk.configuration.redis = { url: Wurk::Test.redis_url }
    Wurk.configuration.reset_redis_pools!
    Wurk.redis { |c| c.call("FLUSHDB") }
    # engine_test_helper boots the dummy app (opening test/dummy/db/test.sqlite3)
    # in the parent before this fork; each worker inherits that connection and
    # must drop it, mirroring Swarm#close_parent_sockets, or workers corrupt
    # each other's queries on the shared SQLite handle.
    ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord::Base)
    SimpleCov.at_fork.call("worker-#{worker}") if ENV["COVERAGE"] && defined?(SimpleCov)
  end
  # Reap every worker before the parent's at-exit SimpleCov merge, without the
  # unbounded Process.waitall that would hang the suite on a stuck child.
  # waitpid2(-1, WNOHANG) returns nil while a child is still running and raises
  # ECHILD once none remain, so nil means "poll again", not "done" — only ECHILD
  # ends the loop, and only a blown deadline is an error.
  Minitest.after_run do
    if ENV["COVERAGE"] && defined?(SimpleCov)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10.0
      loop do
        begin
          pid, status = Process.waitpid2(-1, Process::WNOHANG)
        rescue Errno::ECHILD
          break
        end

        if pid
          raise "Unexpected child status: #{status.inspect} pid=#{pid}" unless status.success?

          next
        end

        raise "Children still running after 10s deadline" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end
  end
end

require_relative "support/redis_namespace"
require_relative "support/swarm_teardown"
require_relative "support/command_spy"

module Wurk
  module Test
    # Suite-wide mutex for tests that mutate process-global `Wurk::Metrics::Statsd`
    # singletons (`.options`, the `increment` method itself) or
    # `Wurk.configuration.dogstatsd`. A class-level mutex doesn't serialize
    # across parallel test classes that touch the same globals — this one does.
    # Pair with a `#run` override on each such class.
    STATSD_MUTEX = Mutex.new

    # Suite-wide mutex for tests that destructively wipe the globally-shared
    # `processes` SET (e.g. `DEL processes`) or read it back and assert a
    # lower bound on its contents. Without this, a `DEL` in ProcessSetTest can
    # land between another test's SADD-identity and its SCARD/SMEMBERS, making
    # the reader see 0 instead of the identity it just registered.
    PROCESSES_MUTEX = Mutex.new

    # Suite-wide mutex for tests that read/write the in-process
    # `Wurk::Processor::{PROCESSED, FAILURE, EXPIRED}` counters and then
    # assert on their value. Without it, the LauncherTest flush_stats
    # tests and MiddlewareExpiryTest's EXPIRED.incr would race.
    PROCESSOR_COUNTER_MUTEX = Mutex.new

    # Base class for non-engine tests.
    class UnitCase < ::Minitest::Test
      include RedisNamespace
      include SwarmTeardown

      def self.parallelize_me!
        # Hook for Minitest's parallel runner.
      end
    end
  end
end
