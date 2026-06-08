# frozen_string_literal: true

require_relative '../test_helper'

# Top-level so the constant resolves in the forked swarm child.
class SwarmCliSentinelWorker
  include Wurk::Job

  def perform(redis_url, sentinel_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', sentinel_key, ::Process.pid.to_s)
    client.call('EXPIRE', sentinel_key, 60)
  ensure
    client&.close
  end
end

# Real fork, real Redis. Exercises the standalone `sidekiqswarm` entry point
# (#170): Wurk::CLI#run_swarm loads, forks worker children per the configured
# topology, and supervises — the only fork-based parallelism path without Rails.
# Boots run_swarm in a subprocess, enqueues a job, asserts a child runs it,
# then SIGTERMs the parent for a graceful drain.
class SwarmCliTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 30.0
  POLL_INTERVAL = 0.1
  SHUTDOWN_TIMEOUT = 10

  def setup
    super
    @ns = "swarmcli-#{::Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @sentinel_key = "#{@ns}-sentinel"
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer&.call('DEL', @sentinel_key, "queue:#{@queue_name}")
    @observer&.close
  ensure
    super
  end

  # The drop-in binary and its native form must ship as executables.
  def test_swarm_binaries_present_and_executable
    %w[wurkswarm sidekiqswarm].each do |bin|
      path = ::File.expand_path("../../exe/#{bin}", __dir__)

      assert ::File.executable?(path), "exe/#{bin} should exist and be executable"
    end
  end

  def test_run_swarm_forks_a_child_that_runs_a_job
    push_sentinel_job
    parent_pid = fork_swarm_cli

    begin
      sentinel_pid = wait_for_key(@sentinel_key)

      assert sentinel_pid, "job never ran via run_swarm within #{POLL_TIMEOUT}s"
      refute_equal parent_pid.to_s, sentinel_pid,
                   'the job should run in a forked child, not the swarm parent'
      refute_equal ::Process.pid.to_s, sentinel_pid,
                   'the job should not run in the test process'
    ensure
      stop(parent_pid)
    end
  end

  private

  def push_sentinel_job
    config = build_config
    cap = config.default_capsule
    cap.queues = [@queue_name]
    Wurk::Client.new(pool: cap.redis_pool, config: config).push(
      'class' => SwarmCliSentinelWorker.name,
      'args' => [Wurk::Test.redis_url, @sentinel_key],
      'queue' => @queue_name
    )
  ensure
    config&.reset_redis_pools!
  end

  def build_config
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:timeout] = SHUTDOWN_TIMEOUT
    config
  end

  # Drives the real CLI#run_swarm in a subprocess so SIGTERM exercises the
  # swarm's own signal handling (install_signals: true).
  def fork_swarm_cli
    ::Process.fork do
      $stdout.reopen(IO::NULL)
      $stderr.reopen(IO::NULL)
      config = build_config
      config.default_capsule.queues = [@queue_name]
      config.topology = Wurk::Topology.flat(count: 1, queues: [@queue_name], concurrency: 1)
      cli = Wurk::CLI.instance
      cli.instance_variable_set(:@config, config)
      cli.run_swarm(boot_app: false, warmup: false)
      exit 0
    end
  end

  def wait_for_key(key)
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      val = @observer.call('GET', key)
      return val if val

      sleep POLL_INTERVAL
    end
    nil
  end

  def stop(pid)
    return unless pid_alive?(pid)

    ::Process.kill('TERM', pid)
    deadline = monotonic_now + SHUTDOWN_TIMEOUT + 5
    while monotonic_now < deadline
      return if ::Process.wait(pid, ::Process::WNOHANG)

      sleep POLL_INTERVAL
    end
    ::Process.kill('KILL', pid)
    ::Process.wait(pid)
  rescue Errno::ECHILD
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
