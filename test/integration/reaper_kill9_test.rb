# frozen_string_literal: true

require_relative '../test_helper'

# Top-level so the forked children (which inherit the constant table but not
# the test's lexical scope) can resolve the class by name.
#
# Each job records completion idempotently in a Redis SET and bumps a global
# execution counter. SET membership means a job re-run after a `kill -9`
# (at-least-once) collapses to a single "done" entry, while the exec counter
# still reflects every actual run — so the test can prove both "every job
# finished" (zero loss) and "no job ran unboundedly" (poison cap holds).
class ReaperKill9Worker
  include Wurk::Job

  def perform(redis_url, done_key, exec_key, job_id)
    client = RedisClient.config(url: redis_url).new_client
    client.call('INCR', exec_key)
    client.call('SADD', done_key, job_id)
    client.call('EXPIRE', done_key, 120)
    client.call('EXPIRE', exec_key, 120)
  ensure
    client&.close
  end
end

# Real forks, real Redis, real `kill -9`. Boots a swarm, floods it with jobs,
# repeatedly SIGKILLs random children mid-run, and asserts the reliable-fetch
# reaper recovers every stranded job: zero loss, zero infinite re-runs.
#
# NEVER mock Redis here. `install_signals: false` so the swarm doesn't poison
# the test process's own signal handlers.
#
# Spec: docs/target/sidekiq-pro.md §3.2. Closes #12 "Done when".
class ReaperKill9Test < Wurk::Test::UnitCase
  parallelize_me!

  JOB_COUNT     = 1000
  CHILDREN      = 3
  CONCURRENCY   = 2
  KILL_ROUNDS   = 8
  DRAIN_TIMEOUT = 90.0
  POLL_INTERVAL = 0.1

  def setup
    super
    @ns         = "reapkill-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @done_key   = "#{@ns}-done"
    @exec_key   = "#{@ns}-execs"
    @config     = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:timeout] = 5
    # Sweep aggressively so a kill -9 victim's stranded jobs are reclaimed
    # within ~1s instead of waiting out the 60s default.
    @config[:super_fetch_reaper_interval] = 1
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer&.call('DEL', @done_key, @exec_key, "queue:#{@queue_name}")
    cleanup_private_lists
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_kill_9_storm_loses_no_jobs_and_never_loops_forever # rubocop:disable Metrics/AbcSize
    enqueue_jobs
    swarm = Wurk::Swarm.new(topology: topology, config: @config, shutdown_timeout: 5)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      kill_random_children(swarm)
      completed = wait_for_drain

      assert completed, "only #{done_count}/#{JOB_COUNT} jobs finished within #{DRAIN_TIMEOUT}s"
      assert_equal JOB_COUNT, done_count, 'every enqueued job must complete at least once (zero loss)'

      # Poison cap (threshold 3) bounds re-runs; an infinite loop would blow
      # this past the ceiling (or hang the drain above). Generous slack for
      # legitimate at-least-once re-execution of killed-mid-flight jobs.
      ceiling = JOB_COUNT * (Wurk::Middleware::PoisonPill::RECOVERY_THRESHOLD + 2)

      assert_operator exec_count, :<=, ceiling, 'executions unbounded — reclaim is looping'
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 15)
    end
  end

  private

  def topology
    Wurk::Topology.flat(count: CHILDREN, queues: [@queue_name], concurrency: CONCURRENCY)
  end

  def enqueue_jobs
    client = Wurk::Client.new(pool: capsule_pool, config: @config)
    JOB_COUNT.times do |i|
      client.push('class' => ReaperKill9Worker.name,
                  'args' => [Wurk::Test.redis_url, @done_key, @exec_key, i.to_s],
                  'queue' => @queue_name)
    end
  end

  def capsule_pool
    cap = @config.default_capsule
    cap.queues = [@queue_name]
    cap.redis_pool
  end

  # SIGKILL a random live child each round, leaving at least one alive. The
  # supervisor respawns victims; their in-flight jobs strand in now-orphaned
  # private lists for the reaper to reclaim.
  def kill_random_children(swarm)
    KILL_ROUNDS.times do
      break if done_count >= JOB_COUNT

      pids = live_child_pids(swarm)
      break if pids.size <= 1

      victim = pids.sample
      kill9(victim)
      sleep 0.4
    end
  end

  def live_child_pids(swarm)
    swarm.children.keys.dup.select { |pid| pid_alive?(pid) }
  rescue StandardError
    []
  end

  def kill9(pid)
    ::Process.kill('KILL', pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def wait_for_drain # rubocop:disable Naming/PredicateMethod
    deadline = monotonic_now + DRAIN_TIMEOUT
    while monotonic_now < deadline
      return true if done_count >= JOB_COUNT

      sleep POLL_INTERVAL
    end
    done_count >= JOB_COUNT
  end

  def done_count
    @observer.call('SCARD', @done_key).to_i
  end

  def exec_count
    @observer.call('GET', @exec_key).to_i
  end

  def cleanup_private_lists
    keys = @observer.call('KEYS', "queue:#{@queue_name}|*")
    @observer.call('DEL', *keys) unless keys.empty?
  rescue StandardError
    nil
  end

  def pid_alive?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
