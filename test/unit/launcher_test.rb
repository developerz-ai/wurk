# frozen_string_literal: true

require_relative '../test_helper'

# Drives Wurk::Launcher against real Redis. Each test owns a unique
# identity (override at the instance level) so parallel runs can't collide
# on the global `processes` SET or per-identity HASH keys. Heartbeat thread
# is exercised via the synchronous public `#heartbeat` method to avoid
# spawning long-lived threads in tests.
class LauncherTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns = "lt-#{Process.pid}-#{object_id}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    cap = @config.default_capsule
    cap.queues = ['default']
    cap.concurrency = 2
    # No manual fetcher wiring — Launcher#run defaults it now (regression #35).
    @config[:tag] = @ns
    @pool = cap.redis_pool
    @cleanup_keys = []
  end

  def teardown
    @pool.with do |c|
      @cleanup_keys.each do |k|
        c.call('SREM', Wurk::Keys::PROCESSES, k) if k.start_with?("host-#{@ns}")
        c.call('UNLINK', k)
      end
      day = Time.now.utc.strftime('%F')
      c.call('UNLINK',
             "stat:processed-#{@ns}",
             "stat:failed-#{@ns}",
             "stat:expired-#{@ns}",
             "stat:processed:#{day}-#{@ns}",
             "stat:failed:#{day}-#{@ns}",
             "stat:expired:#{day}-#{@ns}")
    end
  ensure
    super
  end

  # --- shape ----------------------------------------------------------

  def test_constants
    assert_equal 5 * 365 * 24 * 60 * 60, Wurk::Launcher::STATS_TTL
    assert_equal 10, Wurk::Launcher::BEAT_PAUSE
  end

  def test_aliased_under_sidekiq_namespace
    assert_same Wurk::Launcher, Sidekiq::Launcher
  end

  def test_includes_component
    assert_includes Wurk::Launcher.ancestors, Wurk::Component
  end

  # --- initialize ------------------------------------------------------

  def test_initialize_builds_one_manager_per_capsule
    @config.capsule('extra') { |c| c.concurrency = 1 }

    launcher = Wurk::Launcher.new(@config)

    assert_equal 2, launcher.managers.size
    launcher.managers.each { |m| assert_kind_of Wurk::Manager, m }
  end

  def test_initialize_starts_not_stopping
    launcher = Wurk::Launcher.new(@config)

    refute_predicate launcher, :stopping?
  end

  def test_initialize_accepts_embedded_kwarg
    launcher = Wurk::Launcher.new(@config, embedded: true)

    assert launcher.instance_variable_get(:@embedded)
  end

  def test_initialize_builds_a_scheduler_poller
    launcher = Wurk::Launcher.new(@config)

    assert_instance_of Wurk::Scheduled::Poller, launcher.poller
  end

  # --- run -------------------------------------------------------------

  def test_run_freezes_config
    launcher = Wurk::Launcher.new(@config)
    stub_managers(launcher)

    launcher.run(async_beat: false)

    assert_predicate @config, :frozen?
  end

  # Regression #35: standalone/embedded boots go through run, which must
  # default each capsule's fetcher (only ChildBoot used to wire it).
  def test_run_defaults_the_capsule_fetcher
    assert_nil @config.default_capsule.fetcher
    launcher = Wurk::Launcher.new(@config)
    stub_managers(launcher)

    launcher.run(async_beat: false)

    assert_instance_of Wurk::Fetcher::Reliable, @config.default_capsule.fetcher
  end

  def test_run_starts_each_manager
    launcher = Wurk::Launcher.new(@config)
    started = []
    launcher.managers.each { |m| m.define_singleton_method(:start) { started << self } }

    launcher.run(async_beat: false)

    assert_equal launcher.managers, started
  end

  def test_run_without_async_beat_does_not_spawn_heartbeat_thread
    launcher = Wurk::Launcher.new(@config)
    stub_managers(launcher)

    launcher.run(async_beat: false)

    assert_nil launcher.heartbeat_thread
  end

  def test_run_with_async_beat_spawns_heartbeat_thread
    launcher = Wurk::Launcher.new(@config)
    stub_managers(launcher)
    silence_beat(launcher)

    launcher.run(async_beat: true)
    thread = launcher.heartbeat_thread
    # Thread.new returns before the block sets its name; poll briefly.
    50.times do
      break if thread.name

      sleep 0.01
    end

    assert_kind_of Thread, thread
    assert_equal 'heartbeat', thread.name
  ensure
    launcher.instance_variable_set(:@done, true)
    thread&.kill
  end

  # --- quiet -----------------------------------------------------------

  def test_quiet_flips_stopping_and_quiets_managers
    launcher = Wurk::Launcher.new(@config)
    quieted = []
    launcher.managers.each { |m| m.define_singleton_method(:quiet) { quieted << self } }

    launcher.quiet

    assert_predicate launcher, :stopping?
    assert_equal launcher.managers, quieted
  end

  def test_quiet_is_idempotent
    launcher = Wurk::Launcher.new(@config)
    calls = 0
    launcher.managers.each { |m| m.define_singleton_method(:quiet) { calls += 1 } }

    launcher.quiet
    launcher.quiet

    assert_equal launcher.managers.size, calls
  end

  def test_quiet_fires_quiet_event_in_reverse
    order = []
    @config.on(:quiet) { order << :first }
    @config.on(:quiet) { order << :second }
    launcher = Wurk::Launcher.new(@config)
    silence_managers(launcher)

    launcher.quiet

    assert_equal %i[second first], order
  end

  # --- stop ------------------------------------------------------------

  def test_stop_invokes_quiet_then_manager_stop_with_deadline
    @config[:timeout] = 0
    launcher = Wurk::Launcher.new(@config)
    silence_managers(launcher)
    received = []
    launcher.managers.each do |m|
      m.define_singleton_method(:stop) { |deadline| received << deadline }
    end

    launcher.stop

    assert_predicate launcher, :stopping?
    assert_equal launcher.managers.size, received.size
    received.each { |d| assert_kind_of Float, d }
  end

  def test_stop_fires_shutdown_then_exit_in_reverse
    order = []
    @config.on(:shutdown) { order << :shutdown_first }
    @config.on(:shutdown) { order << :shutdown_second }
    @config.on(:exit)     { order << :exit_first }
    @config.on(:exit)     { order << :exit_second }
    @config[:timeout] = 0

    launcher = Wurk::Launcher.new(@config)
    silence_managers(launcher)
    launcher.managers.each { |m| m.define_singleton_method(:stop) { |_d| nil } }

    launcher.stop

    assert_equal %i[shutdown_second shutdown_first exit_second exit_first], order
  end

  # --- flush_stats -----------------------------------------------------

  def test_flush_stats_noops_when_counters_zero
    Wurk::Test::PROCESSOR_COUNTER_MUTEX.synchronize do
      launcher = Wurk::Launcher.new(@config)
      reset_counters
      write_called = false
      launcher.define_singleton_method(:write_stats) { |_p, _f, _e| write_called = true }

      launcher.flush_stats

      refute write_called, 'write_stats must not run when all counters are zero'
    end
  end

  def test_flush_stats_increments_global_counters
    Wurk::Test::PROCESSOR_COUNTER_MUTEX.synchronize do
      launcher = Wurk::Launcher.new(@config)
      reset_counters
      Wurk::Processor::PROCESSED.incr(3)
      Wurk::Processor::FAILURE.incr(1)
      Wurk::Processor::EXPIRED.incr(2)
      received = nil
      launcher.define_singleton_method(:write_stats) { |p, f, e| received = [p, f, e] }

      launcher.flush_stats

      assert_equal [3, 1, 2], received
    end
  end

  def test_flush_stats_fires_write_stats_when_only_expired_is_nonzero
    Wurk::Test::PROCESSOR_COUNTER_MUTEX.synchronize do
      launcher = Wurk::Launcher.new(@config)
      reset_counters
      Wurk::Processor::EXPIRED.incr(1)
      received = nil
      launcher.define_singleton_method(:write_stats) { |p, f, e| received = [p, f, e] }

      launcher.flush_stats

      assert_equal [0, 0, 1], received
    end
  end

  def test_flush_stats_sets_ttl_on_per_day_keys
    Wurk::Test::PROCESSOR_COUNTER_MUTEX.synchronize do
      launcher = Wurk::Launcher.new(@config)
      reset_counters
      Wurk::Processor::PROCESSED.incr(1)
      Wurk::Processor::FAILURE.incr(1)
      Wurk::Processor::EXPIRED.incr(1)

      launcher.flush_stats

      day = Time.now.utc.strftime('%F')
      ttl_p, ttl_f, ttl_e = read_daily_ttls(day)

      assert_operator ttl_p, :>, 0
      assert_operator ttl_f, :>, 0
      assert_operator ttl_e, :>, 0
    end
  end

  def test_flush_stats_resets_in_process_counters
    Wurk::Test::PROCESSOR_COUNTER_MUTEX.synchronize do
      launcher = Wurk::Launcher.new(@config)
      reset_counters
      Wurk::Processor::PROCESSED.incr(5)
      Wurk::Processor::FAILURE.incr(2)
      Wurk::Processor::EXPIRED.incr(3)

      launcher.flush_stats

      assert_equal 0, Wurk::Processor::PROCESSED.reset
      assert_equal 0, Wurk::Processor::FAILURE.reset
      assert_equal 0, Wurk::Processor::EXPIRED.reset
    end
  end

  # --- heartbeat -------------------------------------------------------

  def test_heartbeat_adds_identity_to_processes_set
    launcher = build_isolated_launcher
    launcher.instance_variable_set(:@started_at, Time.now.to_f)
    track(launcher_identity(launcher))

    launcher.heartbeat
    member = @pool.with { |c| c.call('SISMEMBER', Wurk::Keys::PROCESSES, launcher_identity(launcher)) }

    assert_equal 1, member
  end

  def test_heartbeat_writes_identity_hash_with_60s_ttl
    launcher = build_isolated_launcher
    launcher.instance_variable_set(:@started_at, Time.now.to_f)
    track(launcher_identity(launcher))

    launcher.heartbeat
    ttl = @pool.with { |c| c.call('TTL', launcher_identity(launcher)).to_i }

    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, 60
  end

  def test_heartbeat_writes_info_metadata
    launcher = build_isolated_launcher
    launcher.instance_variable_set(:@started_at, Time.now.to_f)
    track(launcher_identity(launcher))

    launcher.heartbeat
    info = read_info(launcher)

    assert_equal Wurk::VERSION, info['version']
    assert_equal @ns, info['tag']
    refute info['embedded']
  end

  def test_heartbeat_writes_beat_fields
    launcher = build_isolated_launcher
    launcher.instance_variable_set(:@started_at, Time.now.to_f)
    track(launcher_identity(launcher))

    launcher.heartbeat
    fields = read_beat_fields(launcher)

    assert_equal '2', fields[0]     # concurrency
    assert_equal '0', fields[1]     # busy
    assert_equal 'false', fields[3] # quiet
  end

  def test_heartbeat_fires_heartbeat_event_only_on_first_beat
    launcher = build_isolated_launcher
    track(launcher_identity(launcher))
    fires = 0
    @config.on(:heartbeat) { fires += 1 }

    launcher.heartbeat
    launcher.heartbeat

    assert_equal 1, fires
  end

  def test_heartbeat_fires_beat_event_every_time
    launcher = build_isolated_launcher
    track(launcher_identity(launcher))
    fires = 0
    @config.on(:beat) { fires += 1 }

    launcher.heartbeat
    launcher.heartbeat

    assert_equal 2, fires
  end

  def test_heartbeat_drains_signal_list_and_dispatches
    launcher = build_isolated_launcher
    track(launcher_identity(launcher))
    sig_key = "#{launcher_identity(launcher)}-signals"
    @pool.with { |c| c.call('LPUSH', sig_key, 'TSTP') }
    @cleanup_keys << sig_key

    launcher.heartbeat

    assert_predicate launcher, :stopping?
    drained = @pool.with { |c| c.call('LPOP', sig_key) }

    assert_nil drained
  end

  def test_heartbeat_embedded_flag_round_trips
    launcher = build_isolated_launcher(embedded: true)
    track(launcher_identity(launcher))

    launcher.heartbeat

    info = Wurk.load_json(@pool.with { |c| c.call('HGET', launcher_identity(launcher), 'info') })

    assert info['embedded']
  end

  def test_heartbeat_records_work_state_into_work_hash
    launcher = build_isolated_launcher
    track(launcher_identity(launcher))
    Wurk::Processor::WORK_STATE.clear
    Wurk::Processor::WORK_STATE.set('test-tid', queue: 'q', payload: 'p', run_at: 1)
    work_key = "#{launcher_identity(launcher)}:work"
    @cleanup_keys << work_key

    launcher.heartbeat

    hash = work_hash(work_key)

    assert_includes hash.keys, 'test-tid'
  ensure
    Wurk::Processor::WORK_STATE.clear
  end

  def test_heartbeat_sets_ttl_on_work_hash_when_populated
    launcher = build_isolated_launcher
    track(launcher_identity(launcher))
    Wurk::Processor::WORK_STATE.clear
    Wurk::Processor::WORK_STATE.set('test-tid', queue: 'q', payload: 'p', run_at: 1)
    work_key = "#{launcher_identity(launcher)}:work"
    @cleanup_keys << work_key

    launcher.heartbeat
    ttl = @pool.with { |c| c.call('TTL', work_key).to_i }

    assert_operator ttl, :>, 0
  ensure
    Wurk::Processor::WORK_STATE.clear
  end

  def test_heartbeat_unlinks_work_hash_when_no_in_flight
    launcher = build_isolated_launcher
    track(launcher_identity(launcher))
    work_key = "#{launcher_identity(launcher)}:work"
    @pool.with { |c| c.call('HSET', work_key, 'stale-tid', '{}') }
    @cleanup_keys << work_key
    Wurk::Processor::WORK_STATE.clear

    launcher.heartbeat
    exists = @pool.with { |c| c.call('EXISTS', work_key) }

    assert_equal 0, exists
  end

  private

  # Builds a Launcher with an identity unique to this test, so parallel
  # tests can't collide on the global `processes` SET.
  def build_isolated_launcher(embedded: false)
    launcher = Wurk::Launcher.new(@config, embedded: embedded)
    test_identity = "host-#{@ns}:1234:#{object_id.to_s(16)}"
    launcher.define_singleton_method(:identity) { test_identity }
    launcher.define_singleton_method(:hostname) { "host-#{Process.pid}" }
    launcher
  end

  def launcher_identity(launcher)
    launcher.identity
  end

  def track(key)
    @cleanup_keys << key
  end

  def stub_managers(launcher)
    launcher.managers.each { |m| m.define_singleton_method(:start) { nil } }
  end

  def silence_managers(launcher)
    launcher.managers.each do |m|
      m.define_singleton_method(:quiet) { nil }
      m.define_singleton_method(:stop) { |_d| nil }
    end
  end

  def silence_beat(launcher)
    launcher.define_singleton_method(:heartbeat) { nil }
  end

  # redis-client returns HGETALL as either a Hash or a flat Array
  # depending on version; normalize to a Hash for assertion.
  def work_hash(work_key)
    raw = @pool.with { |c| c.call('HGETALL', work_key) }
    raw.is_a?(Hash) ? raw : Hash[*raw]
  end

  def reset_counters
    Wurk::Processor::PROCESSED.reset
    Wurk::Processor::FAILURE.reset
    Wurk::Processor::EXPIRED.reset
  end

  def read_daily_ttls(day)
    @pool.with do |c|
      [
        c.call('TTL', "#{Wurk::Keys::STAT_PROCESSED}:#{day}").to_i,
        c.call('TTL', "stat:failed:#{day}").to_i,
        c.call('TTL', "#{Wurk::Keys::STAT_EXPIRED}:#{day}").to_i
      ]
    end
  end

  def read_info(launcher)
    Wurk.load_json(@pool.with { |c| c.call('HGET', launcher_identity(launcher), 'info') })
  end

  def read_beat_fields(launcher)
    @pool.with { |c| c.call('HMGET', launcher_identity(launcher), 'concurrency', 'busy', 'beat', 'quiet', 'rss') }
  end
end
