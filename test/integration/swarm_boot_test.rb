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

# Records the commands `eval_cached` issues and, when `cold`, fails the first
# EVALSHA with NOSCRIPT — what a restarted or failed-over Redis replies to a
# child still holding a SHA the server has forgotten. Everything else passes
# through to the real connection.
#
# The fault is staged rather than provoked with a real `SCRIPT FLUSH`: the
# script cache is server-global while parallel test workers are isolated only
# by logical DB, so a flush would strand every peer worker's warm SHAs
# mid-test. Same technique as lua_loader_test.rb's ColdCacheConn.
class SwarmColdCacheConn < SimpleDelegator
  attr_reader :command_log

  def initialize(conn, cold:)
    super(conn)
    @command_log = []
    @cold = cold
  end

  def call(*args)
    @command_log << args[0]
    if @cold && args[0] == 'EVALSHA'
      @cold = false
      raise RedisClient::CommandError, "NOSCRIPT No matching script. Use EVAL. #{args[1]}"
    end

    __getobj__.call(*args)
  end
end

# Exercises Wurk::Lua::Loader.eval_cached (the same entry point the fetch/push
# hot paths use) from inside a forked child, on a fresh connection the parent
# never touched. Reports `<script result>|<commands it took>` so the parent can
# tell a plain EVALSHA against the parent-warmed cache from a NOSCRIPT
# self-heal. `release_if_owner` is a single-key, single-arg script (no shared
# `queues` SET to pollute), ideal for an isolated per-test lock key.
class SwarmLuaWorker
  include Wurk::Job

  LOCK_TOKEN = 'swarm-boot-lua-owner'

  def perform(redis_url, lock_key, result_key, cold)
    client = RedisClient.config(url: redis_url).new_client
    conn = SwarmColdCacheConn.new(client, cold: cold)
    released = Wurk::Lua::Loader.eval_cached(conn, :release_if_owner, keys: [lock_key], argv: [LOCK_TOKEN])
    client.call('RPUSH', result_key, "#{released}|#{conn.command_log.join(' ')}")
    client.call('EXPIRE', result_key, 60)
  ensure
    client&.close
  end
end

# Reports whether the cluster leader lock existed the instant this job ran —
# the observable proof that a booting child spends its opening Redis round
# trips on the job path rather than on a leadership CAS.
class SwarmLeaderOrderProbeWorker
  include Wurk::Job

  def perform(redis_url, result_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('RPUSH', result_key, client.call('EXISTS', Wurk::Leader::DEFAULT_KEY).to_s)
    client.call('EXPIRE', result_key, 60)
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
    @lock_key = "#{@ns}-lua-lock-1"
    @lock_key_2 = "#{@ns}-lua-lock-2"
    @lua_result_key = "#{@ns}-lua-result-1"
    @lua_result_key_2 = "#{@ns}-lua-result-2"
    @leader_probe_key = "#{@ns}-leader-probe"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:timeout] = 5
    @observer_pool = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer_pool&.call('DEL', @sentinel_key, @boot_log_key, "queue:#{@queue_name}",
                         private_queue_key(@queue_name), @lock_key, @lock_key_2,
                         @lua_result_key, @lua_result_key_2, @leader_probe_key)
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
      stop_supervisor_thread(supervisor, 10)
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
      stop_supervisor_thread(supervisor, 10)
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

  # #101 boot-audit: Swarm#preload_lua_scripts (swarm.rb) loads every script
  # ONCE, in the parent, before the fork loop — ChildBoot no longer uploads
  # them per child. That the parent loads exactly once and a child loads not at
  # all is pinned deterministically in test/unit/swarm_test.rb and
  # test/unit/child_boot_test.rb; what only a real fork can show is the
  # consequence for a child: on a connection the parent never touched, a single
  # EVALSHA against the parent-warmed cache is enough — no per-child upload —
  # and if the server forgets the script after the fork (restart, failover),
  # eval_cached's own NOSCRIPT rescue heals the child in flight. Both children
  # report the exact command sequence they took, so neither claim can pass on a
  # coincidence.
  def test_lua_scripts_survive_fork_and_a_child_self_heals_a_lost_script # rubocop:disable Metrics/AbcSize,Minitest/MultipleAssertions
    swarm = Wurk::Swarm.new(topology: topology_n(2), config: @config, shutdown_timeout: 5)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      @observer_pool.call('SET', @lock_key, SwarmLuaWorker::LOCK_TOKEN)
      push_lua_job(@lock_key, @lua_result_key, cold: false)

      assert_equal ['1|EVALSHA'], wait_for_list(@lua_result_key),
                   'a child must run release_if_owner in one EVALSHA off the parent-preloaded cache'
      refute @observer_pool.call('GET', @lock_key), 'the lock key should be gone after release_if_owner'

      @observer_pool.call('SET', @lock_key_2, SwarmLuaWorker::LOCK_TOKEN)
      push_lua_job(@lock_key_2, @lua_result_key_2, cold: true)

      assert_equal ['1|EVALSHA SCRIPT EVALSHA'], wait_for_list(@lua_result_key_2),
                   'a child must reload and retry when the server lost the script, and still succeed'
      refute @observer_pool.call('GET', @lock_key_2), 'the self-healed retry must have run the script for real'
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
    end
  end

  # #101 boot-audit: Launcher#run starts managers (fetch/execute) first and
  # `start_periodic_components` last, and Leader holds its first `SET NX EX`
  # back by `leader_initial_wait` (leader.rb) — together they keep a booting
  # process's opening Redis round trips on the job path instead of a leadership
  # CAS. The observable consequence through a real fork: a queued job runs to
  # completion while `dear-leader` still does not exist. The follow-up wait
  # keeps that from passing vacuously — the child must genuinely campaign once
  # the wait elapses, not simply never campaign. (The source order itself is
  # pinned by test/unit/launcher_test.rb; a real fork can't resolve two
  # sub-millisecond boot steps without racing.)
  def test_probe_job_completes_before_the_leader_key_exists
    @config[:leader_initial_wait] = 2
    push_leader_probe_job

    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: 5)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      assert_equal ['0'], wait_for_list(@leader_probe_key),
                   'the queued job must finish before the child campaigns for leadership'
      assert wait_for_key(Wurk::Leader::DEFAULT_KEY),
             'the child must still take the leader lock once the initial wait elapses'
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
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

  def push_lua_job(lock_key, result_key, cold:)
    client = Wurk::Client.new(pool: capsule_pool, config: @config)
    client.push('class' => SwarmLuaWorker.name,
                'args' => [Wurk::Test.redis_url, lock_key, result_key, cold],
                'queue' => @queue_name)
  end

  def push_leader_probe_job
    client = Wurk::Client.new(pool: capsule_pool, config: @config)
    client.push('class' => SwarmLeaderOrderProbeWorker.name,
                'args' => [Wurk::Test.redis_url, @leader_probe_key],
                'queue' => @queue_name)
  end

  def wait_for_key(key) # rubocop:disable Naming/PredicateMethod
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      return true if @observer_pool.call('EXISTS', key) == 1

      sleep POLL_INTERVAL
    end
    false
  end

  # Polls an RPUSH-built result list until it has at least one entry, or the
  # shared POLL_TIMEOUT elapses (returning whatever is there, possibly empty,
  # so a timeout reads as an assertion failure rather than a silent nil).
  def wait_for_list(key)
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      vals = @observer_pool.call('LRANGE', key, 0, -1)
      return vals unless vals.empty?

      sleep POLL_INTERVAL
    end
    @observer_pool.call('LRANGE', key, 0, -1)
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
