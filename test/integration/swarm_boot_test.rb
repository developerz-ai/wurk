# frozen_string_literal: true

require_relative '../test_helper'

# Defined at the top level so Object.const_get(name) resolves the same
# way inside the forked child (which inherits the constant table but
# has no Minitest test-class lexical scope set up).
class SwarmBootSentinelWorker
  include Wurk::Job

  def perform(redis_url, sentinel_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', sentinel_key, ::Process.pid.to_s)
    client.call('EXPIRE', sentinel_key, 60)
  ensure
    client&.close
  end
end

# Real forks, real Redis, real perform. Boot a 2-child swarm, push a job,
# assert a child runs it. NEVER mock Redis here.
#
# `install_signals: false` so the swarm doesn't poison the test process's
# SIGTERM/INT handlers. The supervisor thread calls Process.wait(-1, …),
# so tests inside this class must run sequentially (parallelize_me! is a
# file-level marker; minitest/parallel_fork forks per file, not per test).
class SwarmBootTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 15.0
  POLL_INTERVAL = 0.1

  def setup
    super
    @ns = "swarmboot-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @sentinel_key = "#{@ns}-sentinel"
    @boot_log_key = "#{@ns}-boot-log"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:timeout] = 5
    @observer_pool = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer_pool&.call('DEL', @sentinel_key, @boot_log_key, "queue:#{@queue_name}",
                         private_queue_key(@queue_name))
    @observer_pool&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_swarm_boots_forks_and_runs_a_job_in_a_child # rubocop:disable Metrics/AbcSize,Minitest/MultipleAssertions
    push_sentinel_job
    swarm = Wurk::Swarm.new(topology: topology_n(2), config: @config, shutdown_timeout: 5)
    supervisor = nil

    begin
      pids = swarm.boot(install_signals: false)

      assert_equal 2, pids.size, 'boot should return one PID per slot assignment'
      pids.each { |pid| assert pid_alive?(pid), "expected child #{pid} to be alive after boot" }

      supervisor = Thread.new { swarm.supervise }
      sentinel_pid = wait_for_sentinel

      assert sentinel_pid, "sentinel key #{@sentinel_key} was never written within #{POLL_TIMEOUT}s"
      refute_equal ::Process.pid.to_s, sentinel_pid,
                   'sentinel should have been written by a forked child, not the test process'
      assert_includes pids.map(&:to_s), sentinel_pid,
                      "sentinel writer #{sentinel_pid} should be one of the spawned children #{pids}"
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      supervisor&.join(10) || supervisor&.kill
    end
  end

  # #119 (Ent §7.5): a child whose RSS exceeds the memory limit is recycled
  # through the rolling-restart state machine — a healthy replacement is spawned
  # first, and only once it takes over is the bloated child TERMed. A 1 MB limit
  # guarantees every real Ruby child exceeds it. Each child logs its pid on
  # startup; we boot, wait for the first child to be fully up (so the
  # supervisor's immediate first memory check can't recycle it mid-boot), then
  # start the supervisor and watch a different pid take over AND the original
  # drain out (it lives on briefly past the replacement's boot).
  def test_swarm_recycles_a_child_that_exceeds_the_memory_limit # rubocop:disable Metrics/AbcSize,Minitest/MultipleAssertions
    log_boot_pids
    @config.memory_limit_mb = 1
    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: 5)
    supervisor = nil

    begin
      original = swarm.boot(install_signals: false).first

      assert_equal original.to_s, wait_for_boot_count(1)&.first,
                   "first child #{original} never finished booting"

      supervisor = Thread.new { swarm.supervise }
      pids = wait_for_boot_count(2)

      assert pids, "child was never recycled+respawned within #{POLL_TIMEOUT}s (saw #{boot_pids.inspect})"
      refute_equal pids[0], pids[1], 'the bloated child should be replaced by a new pid'
      assert wait_until_dead(original),
             'the original (bloated) child should be TERMed once its replacement took over'
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      supervisor&.join(10) || supervisor&.kill
    end
  end

  def test_boot_raises_when_topology_is_empty
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.new, config: @config)
    assert_raises(ArgumentError) { swarm.boot(install_signals: false) }
  end

  def test_boot_is_not_re_entrant
    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: 5)

    begin
      swarm.boot(install_signals: false)
      assert_raises(RuntimeError) { swarm.boot(install_signals: false) }
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
    end
  end

  private

  def topology_n(count)
    Wurk::Topology.flat(count: count, queues: [@queue_name], concurrency: 1)
  end

  # Each child appends its pid to a Redis list as it boots (via :startup),
  # giving a race-free, fork-safe record of the recycle → respawn sequence.
  def log_boot_pids
    redis_url = Wurk::Test.redis_url
    key = @boot_log_key
    @config.on(:startup) do
      c = RedisClient.config(url: redis_url).new_client
      c.call('RPUSH', key, ::Process.pid.to_s)
      c.call('EXPIRE', key, 60)
    ensure
      c&.close
    end
  end

  def boot_pids
    @observer_pool.call('LRANGE', @boot_log_key, 0, -1)
  end

  def wait_for_boot_count(count)
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      pids = boot_pids
      return pids if pids.size >= count

      sleep POLL_INTERVAL
    end
    nil
  end

  def push_sentinel_job
    client = Wurk::Client.new(pool: capsule_pool, config: @config)
    client.push('class' => SwarmBootSentinelWorker.name,
                'args' => [Wurk::Test.redis_url, @sentinel_key],
                'queue' => @queue_name)
  end

  def capsule_pool
    cap = @config.default_capsule
    cap.queues = [@queue_name]
    cap.redis_pool
  end

  def wait_for_sentinel
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      val = @observer_pool.call('GET', @sentinel_key)
      return val if val

      sleep POLL_INTERVAL
    end
    nil
  end

  def pid_alive?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def wait_until_dead(pid) # rubocop:disable Naming/PredicateMethod
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      return true unless pid_alive?(pid)

      sleep POLL_INTERVAL
    end
    !pid_alive?(pid)
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  def private_queue_key(queue_name)
    Wurk::Fetcher::Reliable.private_queue_name("queue:#{queue_name}")
  end
end
