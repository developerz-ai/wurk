# frozen_string_literal: true

if ENV['COVERAGE']
  require 'simplecov'
  require 'simplecov-cobertura'
  SimpleCov.start do
    # Both line and branch coverage on lib/ are blocking gates (>= 90%). The
    # Cobertura report is still uploaded by CI for per-file inspection. Branch
    # was ratcheted from ~78% to >=90% in #67; keep new code at parity.
    enable_coverage :branch
    primary_coverage :line
    add_filter '/test/'
    add_filter '/bench/'
    # Count lib files no test ever requires, so an untested file reads as 0%
    # instead of silently dropping out of the denominator.
    track_files 'lib/**/*.rb'
    minimum_coverage line: 90, branch: 90
    formatter SimpleCov::Formatter::CoberturaFormatter
  end
end

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'etc'

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
    # Shifts every worker's DB so concurrent suite runs on one Redis (several
    # agents or terminals, each at NCPU=1) don't all land on DB 1 and FLUSHDB
    # each other: run k uses WURK_TEST_DB_OFFSET=k.
    DB_OFFSET = Integer(ENV.fetch('WURK_TEST_DB_OFFSET', '0'))

    # Parallel worker default — HALF the cores, floored at 1, never above the
    # historical 4. Read the NCPU block below for why one worker per core is the
    # wrong shape for this suite; the flat 4 that used to live there WAS one per
    # core on the 4-core fleet boxes that run `bin/check` as a merge gate, which
    # is the class of red this scales away from (dz#4386, #522).
    #
    # A FUNCTION OF THE CORE COUNT, not a constant derived from this machine's:
    # a test can then state what the rule DOES across machines (1 -> 1, 4 -> 2,
    # 8 -> 4, 64 -> 4) instead of re-deriving the same expression the constant
    # already holds, which is an assertion that cannot fail.
    # The historical default, and the ceiling the rule never exceeds.
    WORKER_CAP = 4

    def self.default_ncpu(cores)
      (cores / 2).clamp(1, WORKER_CAP)
    end

    DEFAULT_NCPU = default_ncpu(Etc.nprocessors)

    # Extra `ruby` arguments for a test-spawned subprocess so the lib code it
    # runs counts toward coverage (test/support/subprocess_coverage.rb).
    SUBPROCESS_COVERAGE =
      (ENV['COVERAGE'] ? ['-r', File.expand_path('support/subprocess_coverage', __dir__)] : []).freeze

    class << self
      attr_accessor :redis_url

      def redis_url_for_db(database)
        base = ENV['REDIS_URL'] || 'redis://localhost:6379/0'
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
        worker_index += DB_OFFSET
        if worker_index >= WORKER_DATABASES
          raise "test worker #{worker_index} has no isolated Redis DB " \
                "(only #{WORKER_DATABASES} for parallel workers); " \
                "keep NCPU + WURK_TEST_DB_OFFSET <= #{WORKER_DATABASES}"
        end

        self.redis_url = redis_url_for_db(worker_index + 1)
        ENV['REDIS_URL'] = redis_url
      end
    end
  end
end

Wurk::Test.assign_redis_db(0) # serial/parent baseline (DB 1), before Wurk loads

require 'wurk'

# Silence the global configuration's logger so default ERROR_HANDLER doesn't
# spam test output. Per-test logger overrides still work — they assign a
# StringIO/NULL logger on a fresh Wurk::Configuration.
Wurk.configuration.logger = Logger.new(IO::NULL)

require 'minitest/autorun'

# Registered before the worker-reaping hook below so it runs after it (Minitest
# runs after_run hooks in reverse): fold each subprocess probe's private
# resultset (test/support/subprocess_coverage.rb) into the shared one just
# before SimpleCov's own at-exit merge reads it.
# Minitest's after_run hooks are inherited by every forked parallel worker, so
# each hook here must check it is the parent: a worker that ran the reap hook
# raised on any leftover non-zero test child, exited with that error, and
# SimpleCov then skipped storing the worker's result — the intermittent
# "worker-1 missing, coverage < 90%" CI failure.
COVERAGE_PARENT_PID = Process.pid
# Resultset timestamps are whole seconds, so this is too.
COVERAGE_STARTED_AT = Time.now.to_i

require_relative 'support/coverage_merge'

if ENV['COVERAGE'] && defined?(SimpleCov)
  require 'fileutils'
  require 'json'
  Minitest.after_run do
    next unless Process.pid == COVERAGE_PARENT_PID

    Dir[File.join(SimpleCov.coverage_path, 'subprocess', '*', '.resultset.json')].each do |path|
      SimpleCov::Result.from_hash(JSON.parse(File.read(path))).each do |result|
        SimpleCov::ResultMerger.store_result(result)
      end
    rescue JSON::ParserError
      warn "skipping unreadable subprocess coverage #{path}"
    end
    FileUtils.rm_rf(File.join(SimpleCov.coverage_path, 'subprocess'))

    # Last thing before SimpleCov's at-exit merge: every worker has been reaped
    # and has stored, so an entry missing now is missing from the merge. Fail
    # on that by name, and stop SimpleCov (its at-exit hook does nothing once
    # `running` is false) so it prints no percentage for a partial suite.
    next unless Minitest.respond_to?(:parallel_fork_number)

    missing = Wurk::Test::CoverageMerge.missing_workers(
      SimpleCov::ResultMerger.read_resultset,
      base: SimpleCov.command_name, workers: Minitest.parallel_fork_number,
      since: COVERAGE_STARTED_AT, now: Time.now.to_i, merge_timeout: SimpleCov.merge_timeout
    )
    next if missing.empty?

    SimpleCov.running = false
    abort Wurk::Test::CoverageMerge.failure_message(missing)
  end
end

# minitest-parallel_fork forks ENV["NCPU"] workers — and it forks that many
# regardless of how many suites there are, so idle extra workers run their
# startup FLUSHDB too. Each worker is isolated on its own Redis logical DB
# (1..14; never 0, and 15 is reserved). More workers than DBs would collide and
# a colliding worker's FLUSHDB would wipe a peer's keys mid-test — the root cause
# of the #84 batch-TTL and #73 periodic-leader flakes. Cap the worker count to
# the number of worker DBs so every worker gets a unique one.
#
# The default is half the cores, capped at the historical 4 — deliberately below
# the core count, which is what this paragraph always argued for and what a flat
# 4 stopped delivering the moment the suite ran on a 4-core machine. The suite
# looks like a pure fan-out of independent classes, but the integration layer
# isn't: a single test boots a swarm of 4 children × 5 threads,
# several use real BLMOVE timeouts, and some pools carry a 1s read timeout. One
# worker per core therefore oversubscribes badly, and the failures it produces
# are wall-clock ones (a drain that doesn't finish, a socket read that times out)
# rather than honest assertion failures. Measured on a 12-core box: `NCPU=12`
# bought ~20% wall clock and cost a red build. Measured on 4 cores (2026-09-19,
# `taskset -c 0-3 ./bin/check` at main): 4m57s at NCPU=4 against 5m24s at
# NCPU=2 — halving the workers costs 9%, because this suite waits far more than
# it computes.
#
# `NCPU` is the knob for a machine with headroom to spare, and `NCPU=1` is how
# to chase an ordering flake. Clamped rather than merely capped so a typo'd
# `NCPU=` (`to_i` → 0) can't fork zero workers; the ceiling is the number of
# isolated Redis DBs, since two workers sharing one would FLUSHDB each other
# mid-test (the root cause of the #84 and #73 flakes).
ENV['NCPU'] = (ENV['NCPU'] || Wurk::Test::DEFAULT_NCPU).to_i.clamp(1, Wurk::Test::WORKER_DATABASES).to_s

begin
  require 'minitest/parallel_fork'
rescue StandardError
  nil
end

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
    Wurk.redis { |c| c.call('FLUSHDB') }
    # engine_test_helper boots the dummy app (opening test/dummy/db/test.sqlite3)
    # in the parent before this fork; each worker inherits that connection and
    # must drop it, mirroring Swarm#close_parent_sockets, or workers corrupt
    # each other's queries on the shared SQLite handle.
    ActiveRecord::Base.connection_handler.clear_all_connections! if defined?(ActiveRecord::Base)
    if ENV['COVERAGE'] && defined?(SimpleCov)
      SimpleCov.at_fork.call("worker-#{worker}")
      # Store this worker's result first thing at exit (at_exit is LIFO, and
      # this is the newest handler): SimpleCov's own handler skips storing when
      # the process exits non-zero, and workers inherit at_exit handlers —
      # Minitest's, Wurk's — any of which can end the worker non-zero, which
      # silently dropped that worker's whole coverage from the merge.
      # Pid-guarded: processes a test forks from this worker (a swarm
      # supervisor, its children) inherit the handler and must exit fast.
      worker_pid = Process.pid
      at_exit { SimpleCov::ResultMerger.store_result(SimpleCov.result) if Process.pid == worker_pid }
    end
  end
  # Reap every worker before the parent's at-exit SimpleCov merge, without the
  # unbounded Process.waitall that would hang the suite on a stuck child.
  # waitpid2(-1, WNOHANG) returns nil while a child is still running and raises
  # ECHILD once none remain, so nil means "poll again", not "done" — only ECHILD
  # ends the loop, and only a blown deadline is an error.
  Minitest.after_run do
    if ENV.fetch('COVERAGE', nil) && defined?(SimpleCov) && Process.pid == COVERAGE_PARENT_PID
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

        raise 'Children still running after 10s deadline' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end
  end
end

require_relative 'support/redis_namespace'
require_relative 'support/swarm_teardown'
require_relative 'support/command_spy'
require_relative 'support/recording_pool'
require_relative 'support/thread_leak_guard'

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

    # Suite-wide mutex for tests that mutate Wurk's process-global state
    # (`@strict_args_mode`, `@default_job_options`, `@testing_mode`, `@server`).
    # Shared by every such class — a class-local mutex would let JobUtilTest's
    # `strict_args!(false)` land inside ClientVerifyJsonTest's `assert_raises`.
    GLOBAL_STATE_MUTEX = Mutex.new

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
