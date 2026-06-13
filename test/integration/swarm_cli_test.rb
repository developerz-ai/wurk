# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'

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
    @startup_key = "#{@ns}-startup"
    @fork_key = "#{@ns}-fork"
    @preload_key = "#{@ns}-preload"
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer&.call('DEL', @sentinel_key, @startup_key, @fork_key, @preload_key, "queue:#{@queue_name}")
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

  # Regression #236 (real fork): the dashboard "Quiet" button does
  # `Sidekiq::ProcessSet#quiet!`, which LPUSHes `TSTP` to `<identity>-signals`.
  # A swarm child must apply that quiet WITHOUT killing its heartbeat — it has to
  # keep beating, publish `quiet=true`, and stay in the live `processes` SET.
  # Before the fix the heartbeat loop ran `until @done` and quiet flipped @done,
  # so the child stopped beating, never reported quiet, and expired off the
  # dashboard's Busy page.
  def test_dashboard_quiet_keeps_child_beating_and_reports_quiet
    parent_pid = fork_swarm_cli

    begin
      child_id = wait_for_child_identity

      refute_nil child_id, "swarm child never registered within #{POLL_TIMEOUT}s"
      assert_equal 'false', @observer.call('HGET', child_id, 'quiet'),
                   'precondition: a fresh child is not quieted'

      # Exactly what the dashboard does.
      @observer.call('LPUSH', "#{child_id}-signals", 'TSTP')

      assert_equal 'true', wait_for_quiet_flag(child_id),
                   'quieted swarm child never published quiet=true — heartbeat died on quiet (#236)'
      assert_equal 1, @observer.call('SISMEMBER', Wurk::Keys::PROCESSES, child_id),
                   'a quieted child must stay in the live process set, not vanish (#236)'
    ensure
      stop(parent_pid)
    end
  end

  # config.on(:startup) hooks must fire in each swarm worker child before its
  # managers spin up (Sidekiq lifecycle contract).
  def test_run_swarm_fires_startup_in_child
    startup_key = @startup_key
    redis_url = Wurk::Test.redis_url
    parent_pid = fork_swarm_cli do |config|
      config.on(:startup) do
        c = RedisClient.config(url: redis_url).new_client
        c.call('SET', startup_key, ::Process.pid.to_s)
        c.call('EXPIRE', startup_key, 60)
        c.close
      end
    end

    begin
      assert wait_for_key(@startup_key), ':startup hook never fired in a swarm child'
    ensure
      stop(parent_pid)
    end
  end

  # config.on(:fork) must fire inside each forked child (after the swarm's
  # internal AR/Redis reconnect, before fetching) and NEVER in the parent
  # (Ent §7.4). The hook records the running pid; we assert it ran in a child,
  # not the supervising parent or the test process.
  def test_run_swarm_fires_fork_in_child
    fork_key = @fork_key
    redis_url = Wurk::Test.redis_url
    parent_pid = fork_swarm_cli do |config|
      config.on(:fork) { record_pid_to_redis(redis_url, fork_key) }
    end

    begin
      hook_pid = wait_for_key(@fork_key)

      assert hook_pid, ':fork hook never fired in a swarm child'
      refute_equal parent_pid.to_s, hook_pid, ':fork must not fire in the swarm parent'
      refute_equal ::Process.pid.to_s, hook_pid, ':fork must not fire in the test process'
    ensure
      stop(parent_pid)
    end
  end

  # Real fork: the swarm PARENT must Bundler.require the SIDEKIQ_PRELOAD groups
  # before forking children (Ent §7.2). Boot run_swarm with boot_app:true so the
  # preload path runs; observe — via a Bundler.require shim that records the
  # groups to Redis instead of loading gems — that the configured groups were
  # required in the parent, and that it still forks a child that runs the job.
  def test_run_swarm_parent_honors_sidekiq_preload_before_forking
    require_file = ::File.join(::Dir.tmpdir, "#{@ns}-app.rb")
    ::File.write(require_file, "# swarm preload boot sentinel\n")
    push_sentinel_job
    parent_pid = fork_swarm_parent(require_file)

    begin
      groups = wait_for_key(@preload_key)

      assert groups, "swarm parent never ran the SIDEKIQ_PRELOAD require within #{POLL_TIMEOUT}s"
      assert_equal 'default,assets', groups,
                   'swarm parent should Bundler.require the configured preload groups before fork'
      assert wait_for_key(@sentinel_key), 'swarm child never ran the job after preload'
    ensure
      stop(parent_pid)
      ::FileUtils.rm_f(require_file)
    end
  end

  private

  # Forks the real CLI#run_swarm with boot_app:true and SIDEKIQ_PRELOAD set. The
  # Bundler.require shim is installed inside the child only (the parent test
  # process is untouched by fork) and records the requested groups to Redis.
  def fork_swarm_parent(require_file)
    ::Process.fork do
      $stdout.reopen(IO::NULL)
      $stderr.reopen(IO::NULL)
      ENV['SIDEKIQ_PRELOAD'] = 'default,assets'
      record_bundler_groups_to_redis(@preload_key)
      boot_swarm_child(require_file)
    end
  end

  def record_bundler_groups_to_redis(preload_key)
    redis_url = Wurk::Test.redis_url
    ::Bundler.define_singleton_method(:require) do |*groups|
      c = RedisClient.config(url: redis_url).new_client
      c.call('SET', preload_key, groups.join(','))
      c.call('EXPIRE', preload_key, 60)
      c.close
    end
  end

  # Records the running pid to Redis from inside a forked child (used by the
  # :fork hook assertion). A fresh client because the parent's pool must not
  # cross the fork.
  def record_pid_to_redis(url, key)
    c = RedisClient.config(url: url).new_client
    c.call('SET', key, ::Process.pid.to_s)
    c.call('EXPIRE', key, 60)
  ensure
    c&.close
  end

  def boot_swarm_child(require_file)
    config = build_config
    config[:require] = require_file
    config.default_capsule.queues = [@queue_name]
    config.topology = Wurk::Topology.flat(count: 1, queues: [@queue_name], concurrency: 1)
    cli = Wurk::CLI.instance
    cli.instance_variable_set(:@config, config)
    cli.run_swarm(boot_app: true, warmup: false)
    exit 0
  end

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
      yield config if block_given?
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

  # Poll the child's published `quiet` field until it reads "true" (or timeout),
  # returning whatever it last read so the caller asserts on the value.
  def wait_for_quiet_flag(identity)
    deadline = monotonic_now + POLL_TIMEOUT
    loop do
      val = @observer.call('HGET', identity, 'quiet')
      return val if val == 'true' || monotonic_now >= deadline

      sleep POLL_INTERVAL
    end
  end

  # Poll the live `processes` SET for *this* test's child, identified by the
  # unique queue it fetches (parallel test methods share one Redis DB, so match
  # on queue rather than assuming a single registrant).
  def wait_for_child_identity
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      id = child_identity
      return id if id

      sleep POLL_INTERVAL
    end
    nil
  end

  def child_identity
    @observer.call('SMEMBERS', Wurk::Keys::PROCESSES).find do |id|
      info = @observer.call('HGET', id, 'info')
      info && Array(Wurk.load_json(info)['queues']).include?(@queue_name)
    rescue ::JSON::ParserError
      false
    end
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
