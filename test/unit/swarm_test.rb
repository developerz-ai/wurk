# frozen_string_literal: true

require_relative '../test_helper'

# Pure-Ruby surface of Wurk::Swarm — initialization, validation, and the
# parts that DON'T fork. The fork-real integration sits in
# test/integration/swarm_boot_test.rb.
class SwarmTest < Wurk::Test::UnitCase
  parallelize_me!

  # Fork-free swarm: `fork_child` hands back a fake PID so `boot` fills
  # `@children` for real without spawning processes.
  class FakeForkSwarm < Wurk::Swarm
    private

    def fork_child(_slot, _idx)
      @fake_pid = (@fake_pid || 9000) + 1
    end
  end

  # Fork-free swarm that snapshots the supervisor pool's command log the moment
  # the first (faked) fork happens — the Lua preload has to be finished by then
  # or children boot against a cold script cache.
  class PreloadProbeSwarm < FakeForkSwarm
    attr_accessor :commands
    attr_reader :commands_at_first_fork

    private

    def fork_child(slot, idx)
      @commands_at_first_fork ||= commands.dup
      super
    end
  end

  # Fork-free swarm that snapshots how far the config had settled at the moment
  # of the first (faked) fork: what a child inherits has to be in place by then,
  # and what a child still writes for its own slot must not be.
  class FreezeProbeSwarm < FakeForkSwarm
    attr_reader :config_at_first_fork

    private

    def fork_child(slot, idx)
      @config_at_first_fork ||= {
        frozen: @config.frozen?,
        capsules_open: @config.capsules.each_value.none?(&:frozen?),
        chains_built: @config.default_capsule.instance_variable_get(:@server_chain)
      }
      super
    end
  end

  # Stands in for a supervisor pool whose Redis is unreachable, without paying
  # RedisPool#with's real connect backoff (seconds) in a unit test.
  class DeadPool
    def with(*) = raise(RedisClient::CannotConnectError, 'connection refused')
    def disconnect! = nil
  end

  def setup
    super
    @config = Wurk::Configuration.new
    # The supervisor-pool tests open real sockets off this config, so pin it to
    # the worker's isolated logical DB rather than inheriting whatever
    # REDIS_URL happens to hold — the class runs under parallelize_me!.
    @config.redis = { url: Wurk::Test.redis_url }
    @config.logger = ::Logger.new(IO::NULL)
    @swarms = []
  end

  # The supervisor pool is the swarm's own; `redis_pool` assertions build a
  # capsule pool on top of it. Both are returned here or the class leaks a
  # connection per test.
  def teardown
    @swarms.each { |swarm| swarm.send(:close_supervisor_pool) }
    @config.reset_redis_pools!
  ensure
    super
  end

  # --- initialization --------------------------------------------------

  def test_initialize_with_empty_topology
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.new, config: @config)

    assert_empty swarm.children
    assert_kind_of Wurk::Topology, swarm.topology
  end

  def test_initialize_defaults_shutdown_timeout
    swarm = Wurk::Swarm.new(topology: topology, config: @config)

    assert_equal Wurk::Swarm::DEFAULT_SHUTDOWN_TIMEOUT,
                 swarm.instance_variable_get(:@shutdown_timeout)
  end

  def test_initialize_accepts_memory_limit
    swarm = Wurk::Swarm.new(topology: topology, config: @config, memory_limit: 500_000)

    assert_equal 500_000, swarm.instance_variable_get(:@memory_limit)
  end

  # #119: with no explicit memory_limit, the swarm picks up the config's
  # SIDEKIQ_MAXMEM_MB-derived threshold (in KB) so the railtie / wurkswarm /
  # demo entry points all honor it without each passing it through.
  def test_initialize_defaults_memory_limit_from_config
    @config.memory_limit_mb = 750
    swarm = Wurk::Swarm.new(topology: topology, config: @config)

    assert_equal 750 * 1024, swarm.instance_variable_get(:@memory_limit)
  end

  def test_initialize_memory_limit_nil_when_config_unset
    swarm = Wurk::Swarm.new(topology: topology, config: @config)

    assert_nil swarm.instance_variable_get(:@memory_limit)
  end

  # --- boot validation --------------------------------------------------

  def test_boot_raises_on_empty_topology
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.new, config: @config)

    assert_raises(ArgumentError) { swarm.boot(install_signals: false) }
  end

  # --- boot-time Lua preload --------------------------------------------

  # `SCRIPT LOAD` is server-global, so the fleet shares one upload. Children
  # used to each re-upload the full set on their boot-critical path; the parent
  # now does it once, and it must land BEFORE the first fork or a child can
  # still reach its first EVALSHA against a cold cache.
  def test_boot_uploads_every_lua_script_before_the_first_fork
    swarm = preload_probe_swarm

    swarm.boot(install_signals: false)

    assert_equal Wurk::Lua::SCRIPTS.size, script_loads(swarm.commands_at_first_fork),
                 'the parent must upload every Lua script before forking'
  end

  def test_boot_uploads_the_lua_scripts_only_once_for_the_whole_fleet
    swarm = preload_probe_swarm(slots: 3)

    swarm.boot(install_signals: false)

    assert_equal Wurk::Lua::SCRIPTS.size, script_loads(swarm.commands),
                 'the preload must not repeat per slot'
  end

  # A Redis that is unreachable at boot must not take the supervisor with it:
  # children still PING (and crash into respawn backoff on a dead Redis), and
  # `Lua::Loader.eval_cached` reloads on NOSCRIPT, so the cold cache self-heals.
  def test_boot_survives_an_unreachable_redis_during_the_preload
    swarm = bare_swarm(FakeForkSwarm)
    swarm.instance_variable_set(:@supervisor_pool, DeadPool.new)

    pids = swarm.boot(install_signals: false)

    assert_equal 1, pids.size, 'a failed preload must not abort the fork loop'
  end

  # --- boot-time config freeze ------------------------------------------

  # The slot-independent config settles in the parent so every child inherits
  # the same pages copy-on-write instead of rebuilding and dirtying its own —
  # and an option written after the fork raises in the child that wrote it.
  def test_boot_settles_the_shared_config_before_the_first_fork
    swarm = bare_swarm(FreezeProbeSwarm)

    swarm.boot(install_signals: false)

    assert swarm.config_at_first_fork[:frozen], 'the options must be frozen before the first fork'
    refute_nil swarm.config_at_first_fork[:chains_built], 'the middleware chains must be built before the fork'
  end

  # ChildBoot#apply_slot_to_config writes queues + concurrency, and the child
  # opens its own pools, so the capsules have to cross the fork still open.
  def test_boot_leaves_the_capsules_open_for_the_child_slot
    swarm = bare_swarm(FreezeProbeSwarm)

    swarm.boot(install_signals: false)

    assert swarm.config_at_first_fork[:capsules_open], 'a frozen capsule would break the slot assignment'
    @config.default_capsule.concurrency = 4 # must not raise post-boot either

    assert_equal 4, @config.default_capsule.concurrency
  end

  # --- owner-pid guard --------------------------------------------------

  # A forked child inherits the swarm object *and* the host's `at_exit` hooks —
  # and rails_boot registers `at_exit { swarm.shutdown }` — so ChildBoot's
  # `exit` runs a full drain inside the child, where `@children` lists the
  # child's SIBLINGS. Every supervisory action must no-op off the process that
  # forked them. Real-fork proof: test/integration/swarm_supervision_test.rb.
  def test_shutdown_off_the_owning_process_never_drains
    swarm = non_owner_swarm

    swarm.shutdown(timeout: 0)

    refute swarm.instance_variable_get(:@stopping), 'a non-owner must never start a drain'
    refute_empty swarm.children, 'a non-owner reached hard_kill_stragglers and cleared the fleet'
  end

  # relay_signal, hard_kill_stragglers and the restart machine's `kill:`
  # callback all signal through safe_kill, so that is where the owner check
  # lives. Signal 0 sends nothing but reports delivery — 1 when the kill would
  # have gone out, nil once the guard swallowed it.
  def test_safe_kill_delivers_only_from_the_owning_process
    assert_equal 1, owner_swarm.send(:safe_kill, ::Process.pid, 0)
    assert_nil non_owner_swarm.send(:safe_kill, ::Process.pid, 0)
  end

  # rails_boot's `at_exit` fires on the host's main thread while the supervise
  # thread is reaping / respawning / restarting through the same child table, so
  # the request may only raise a flag — the drain itself belongs to the
  # supervise loop. Real-fork proof that it observes it:
  # test/integration/swarm_supervision_test.rb.
  def test_request_shutdown_never_drains_on_the_calling_thread
    swarm = owner_swarm

    swarm.request_shutdown

    refute swarm.instance_variable_get(:@stopping), 'request_shutdown must not drain inline'
    refute_empty swarm.children, 'the fleet must be left to the supervise thread'
  end

  def test_supervise_returns_at_once_off_the_owning_process
    swarm = non_owner_swarm
    thread = Thread.new { swarm.supervise }
    returned = thread.join(5)
    thread.kill

    assert returned, 'supervise must return immediately off the owning process'
  end

  # --- supervisor Redis pool (boot-ordering steps 3/5) ------------------

  # `boot` closes every parent-side socket before forking (step 3) and each
  # child opens its own (step 5). The restart machine polls `heartbeat_seen?`
  # for the life of the swarm, so running that probe on the capsule main pool
  # reopened it — in the parent, at capsule size — right after step 3 closed it.
  def test_heartbeat_probe_never_reopens_the_capsule_pool
    swarm = owner_swarm

    swarm.send(:heartbeat_seen?, 999_999)

    assert_nil @config.default_capsule.instance_variable_get(:@redis_pool),
               'the heartbeat probe reopened the parent capsule pool that boot had closed'
  end

  def test_supervisor_pool_is_a_dedicated_single_connection
    swarm = bare_swarm
    pool = swarm.send(:supervisor_pool)

    assert_equal 1, pool.size, 'one SISMEMBER per tick needs exactly one connection'
    assert_same pool, swarm.send(:supervisor_pool), 'the pool must be built once, not per probe'
    refute_same @config.redis_pool, pool, 'the supervisor must not draw on a capsule pool'
  end

  # Every fork — boot, crash respawn, rolling restart, memory recycle — runs
  # through `fork_child`, and the probe reopens the pool between them, so the
  # close belongs immediately before Process.fork rather than only at boot.
  def test_fork_closes_the_supervisor_pool_before_forking
    swarm = bare_swarm
    pool = swarm.send(:supervisor_pool)
    inherited = :never_forked
    fake_fork = lambda {
      inherited = swarm.instance_variable_get(:@supervisor_pool)
      9001 # a pid, so fork_child takes the parent branch and never boots a child
    }

    with_stubbed_fork(fake_fork) { swarm.send(:spawn_child, topology.assignments.first, 0) }

    assert_nil inherited, 'the child inherited the parent supervisor socket'
    assert_raises(ConnectionPool::PoolShuttingDownError) { pool.with { |c| c.call('PING') } }
  end

  # ConnectionPool#shutdown is terminal: without dropping the reference too, the
  # first probe after a respawn would raise PoolShuttingDownError forever and
  # every rolling restart would fall back to its heartbeat timeout.
  def test_supervisor_pool_rebuilds_after_a_fork_closed_it
    swarm = bare_swarm
    closed = swarm.send(:supervisor_pool)
    swarm.send(:close_supervisor_pool)
    rebuilt = swarm.send(:supervisor_pool)

    pong = rebuilt.with { |c| c.call('PING') }

    refute_same closed, rebuilt
    assert_equal 'PONG', pong
  end

  def test_closing_an_unbuilt_supervisor_pool_is_a_no_op
    swarm = bare_swarm

    assert_nil swarm.send(:close_supervisor_pool)
    refute_nil swarm.send(:supervisor_pool)
  end

  def test_shutdown_closes_the_supervisor_pool
    swarm = bare_swarm
    swarm.instance_variable_set(:@owner_pid, ::Process.pid)
    pool = swarm.send(:supervisor_pool)

    swarm.shutdown(timeout: 0)

    assert_nil swarm.instance_variable_get(:@supervisor_pool), 'the parent kept a Redis socket past the drain'
    assert_raises(ConnectionPool::PoolShuttingDownError) { pool.with { |c| c.call('PING') } }
  end

  # --- includes -----------------------------------------------------

  def test_includes_component
    assert_includes Wurk::Swarm.ancestors, Wurk::Component
  end

  # --- constants ---------------------------------------------------------

  def test_default_shutdown_timeout_matches_sidekiq
    assert_equal 25, Wurk::Swarm::DEFAULT_SHUTDOWN_TIMEOUT
  end

  def test_supervisor_tunables_are_numeric # rubocop:disable Minitest/MultipleAssertions
    assert_kind_of Numeric, Wurk::Swarm::SUPERVISE_TICK
    assert_kind_of Numeric, Wurk::Swarm::RESPAWN_BACKOFF
    assert_kind_of Numeric, Wurk::Swarm::HEARTBEAT_WAIT
    assert_kind_of Numeric, Wurk::Swarm::MEMORY_CHECK_INTERVAL
  end

  private

  def topology(count = 1)
    Wurk::Topology.flat(count: count, queues: ['default'], concurrency: 1)
  end

  # A fork-free swarm whose supervisor pool records what boot sends to Redis.
  # The pool is pre-seeded so `supervisor_pool`'s memo hands the recorder to
  # `preload_lua_scripts`; teardown returns the wrapped connection.
  def preload_probe_swarm(slots: 1)
    swarm = PreloadProbeSwarm.new(topology: topology(slots), config: @config).tap { |s| @swarms << s }
    swarm.commands = []
    recorder = Wurk::Test::RecordingPool.new(@config.new_redis_pool(1, 'swarm-preload-test'), swarm.commands)
    swarm.instance_variable_set(:@supervisor_pool, recorder)
    swarm
  end

  def script_loads(commands)
    commands.count { |cmd| cmd.first(2) == %w[SCRIPT LOAD] }
  end

  # Tracked so teardown returns the one supervisor connection a probe opens.
  def bare_swarm(klass = Wurk::Swarm)
    klass.new(topology: topology, config: @config).tap { |swarm| @swarms << swarm }
  end

  def owner_swarm
    bare_swarm(FakeForkSwarm).tap { |swarm| swarm.boot(install_signals: false) }
  end

  # A booted swarm exactly as one of its own forked children holds it: the same
  # `@children` map, a different PID.
  def non_owner_swarm
    owner_swarm.tap { |swarm| swarm.instance_variable_set(:@owner_pid, ::Process.pid + 1) }
  end

  # Minitest 6 dropped minitest/mock; this hand-rolled stub swaps Process.fork
  # for `replacement` so `fork_child` runs its real pre-fork work without
  # spawning anything. Test classes get their own worker process and tests run
  # serially inside it, so nothing else forks while this is installed.
  def with_stubbed_fork(replacement)
    sc = ::Process.singleton_class
    original = ::Process.method(:fork)
    sc.define_method(:fork) { |*args, &blk| replacement.call(*args, &blk) }
    yield
  ensure
    sc.define_method(:fork) { |*a, &b| original.call(*a, &b) }
  end
end
