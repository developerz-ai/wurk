# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  require "simplecov-cobertura"
  SimpleCov.start do
    # Branch is still measured (and shown in the Cobertura report uploaded by
    # CI), but the *blocking* gate is on line coverage — branch is tracked to
    # ratchet up over time, not enforced yet (currently ~77%). See #29.
    enable_coverage :branch
    primary_coverage :line
    add_filter "/test/"
    add_filter "/bench/"
    minimum_coverage line: 90
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
    REDIS_DATABASES = 15

    class << self
      attr_accessor :redis_url

      def redis_url_for_db(database)
        base = ENV["REDIS_URL"] || "redis://localhost:6379/0"
        base.match?(%r{/\d+\z}) ? base.sub(%r{/\d+\z}, "/#{database}") : "#{base}/#{database}"
      end

      # Point this process at its own DB. Updates ENV so fresh Configurations and
      # RedisPools pick it up, and caches the URL for explicit-pool tests.
      def assign_redis_db(worker_index)
        self.redis_url = redis_url_for_db((worker_index % REDIS_DATABASES) + 1)
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
    SimpleCov.at_fork.call("worker-#{worker}") if ENV["COVERAGE"] && defined?(SimpleCov)
  end
  Minitest.after_run { Process.waitall } if ENV["COVERAGE"] && defined?(SimpleCov)
end

require_relative "support/redis_namespace"

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

      def self.parallelize_me!
        # Hook for Minitest's parallel runner.
      end
    end
  end
end
