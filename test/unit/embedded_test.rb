# frozen_string_literal: true

require_relative '../test_helper'

# Drives Wurk::Embedded against a real Redis. Each test uses a fresh
# Wurk::Configuration so the global singleton isn't mutated; the launcher
# itself is stubbed where we just want to verify lifecycle delegation.
class EmbeddedTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns = "embed-#{Process.pid}-#{object_id}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.concurrency = 2
    @config.default_capsule.queues = ['default']
    # No manual fetcher wiring — Launcher#run defaults it now (regression #35).
    @config[:tag] = @ns
  end

  # --- shape ----------------------------------------------------------

  def test_aliased_under_sidekiq_namespace
    assert_same Wurk::Embedded, Sidekiq::Embedded
  end

  def test_includes_component
    assert_includes Wurk::Embedded.ancestors, Wurk::Component
  end

  def test_initialize_assigns_config_and_no_launcher
    embedded = Wurk::Embedded.new(@config)

    assert_same @config, embedded.config
    assert_nil embedded.launcher
  end

  # --- run -------------------------------------------------------------

  def test_run_sets_default_tag_when_blank
    @config[:tag] = nil
    embedded = bypass_io(Wurk::Embedded.new(@config))

    embedded.run

    refute_nil @config[:tag]
  end

  def test_run_keeps_existing_tag
    embedded = bypass_io(Wurk::Embedded.new(@config))

    embedded.run

    assert_equal @ns, @config[:tag]
  end

  def test_run_fires_startup_event
    fires = 0
    @config.on(:startup) { fires += 1 }
    embedded = bypass_io(Wurk::Embedded.new(@config))

    embedded.run

    assert_equal 1, fires
  end

  def test_run_reraises_startup_hook_errors
    @config.on(:startup) { raise 'boom' }
    embedded = bypass_io(Wurk::Embedded.new(@config))

    err = assert_raises(RuntimeError) { embedded.run }

    assert_match(/boom/, err.message)
  end

  def test_run_builds_launcher_with_embedded_flag
    embedded = Wurk::Embedded.new(@config)
    stub_redis!(embedded)
    received = nil
    embedded.define_singleton_method(:build_launcher) do
      received = true
      real = Wurk::Launcher.new(@config, embedded: true)
      real.define_singleton_method(:run) { |**_| nil }
      real
    end

    embedded.run

    assert received
    assert embedded.launcher.instance_variable_get(:@embedded)
  end

  def test_run_invokes_launcher_run
    embedded = Wurk::Embedded.new(@config)
    stub_redis!(embedded)
    ran = false
    embedded.define_singleton_method(:build_launcher) do
      fake = Object.new
      fake.define_singleton_method(:run) { ran = true }
      fake
    end

    embedded.run

    assert ran
  end

  # --- partial boot rollback -------------------------------------------

  # A4: `run` raising leaves the host believing Wurk never started, so a
  # launcher that came up halfway would keep fetching, beating and campaigning
  # for the leader lock with nobody holding a reference to it.
  def test_run_stops_a_launcher_that_raised_mid_boot
    stopped = 0
    embedded = embedded_with_launcher(run: -> { raise 'health port already bound' }, stop: -> { stopped += 1 })

    err = assert_raises(RuntimeError) { embedded.run }

    assert_equal 'health port already bound', err.message
    assert_equal 1, stopped, 'a partial boot must be rolled back'
  end

  # The rollback is guarded so the caller sees why the boot failed.
  def test_run_reports_a_failing_rollback_and_raises_the_boot_error
    reported = []
    @config.error_handlers << ->(ex, ctx, _cfg) { reported << [ex.message, ctx[:context]] }
    embedded = embedded_with_launcher(run: -> { raise 'health port already bound' },
                                      stop: -> { raise 'rollback exploded' })

    err = assert_raises(RuntimeError) { embedded.run }

    assert_equal 'health port already bound', err.message
    assert_includes reported, ['rollback exploded', 'embedded-boot-rollback']
  end

  # --- redis validation -----------------------------------------------

  def test_run_raises_when_redis_too_old
    embedded = Wurk::Embedded.new(@config)
    embedded.define_singleton_method(:fire_event) { |*| nil }
    fake_pool = Object.new
    fake_pool.define_singleton_method(:info) { { 'redis_version' => '6.2.0', 'maxmemory_policy' => 'noeviction' } }
    @config.define_singleton_method(:redis_pool) { fake_pool }

    err = assert_raises(RuntimeError) { embedded.run }

    assert_match(/Redis 7\.0\.0 or greater/, err.message)
  end

  def test_run_warns_on_non_noeviction_policy
    io = StringIO.new
    @config.logger = ::Logger.new(io)
    embedded = Wurk::Embedded.new(@config)
    bypass_io(embedded)
    fake_pool = Object.new
    fake_pool.define_singleton_method(:info) { { 'redis_version' => '7.2.0', 'maxmemory_policy' => 'allkeys-lru' } }
    @config.define_singleton_method(:redis_pool) { fake_pool }

    embedded.run

    assert_match(/will evict Wurk data/, io.string)
  end

  def test_run_silent_on_noeviction_policy
    io = StringIO.new
    @config.logger = ::Logger.new(io)
    @config.logger.level = ::Logger::WARN
    embedded = Wurk::Embedded.new(@config)
    bypass_io(embedded)
    fake_pool = Object.new
    fake_pool.define_singleton_method(:info) { { 'redis_version' => '7.2.0', 'maxmemory_policy' => 'noeviction' } }
    @config.define_singleton_method(:redis_pool) { fake_pool }

    embedded.run

    refute_match(/will evict/, io.string)
  end

  # --- quiet / stop ---------------------------------------------------

  def test_quiet_before_run_is_noop
    embedded = Wurk::Embedded.new(@config)

    assert_nil embedded.quiet
  end

  def test_stop_before_run_is_noop
    embedded = Wurk::Embedded.new(@config)

    assert_nil embedded.stop
  end

  def test_quiet_delegates_to_launcher
    embedded = Wurk::Embedded.new(@config)
    fake = Object.new
    quieted = false
    fake.define_singleton_method(:quiet) { quieted = true }
    embedded.instance_variable_set(:@launcher, fake)

    embedded.quiet

    assert quieted
  end

  def test_stop_delegates_to_launcher
    embedded = Wurk::Embedded.new(@config)
    fake = Object.new
    stopped = false
    fake.define_singleton_method(:stop) { stopped = true }
    embedded.instance_variable_set(:@launcher, fake)

    embedded.stop

    assert stopped
  end

  # --- end-to-end heartbeat marks embedded: true ----------------------

  def test_launcher_built_with_embedded_true_marks_heartbeat
    launcher = Wurk::Launcher.new(@config, embedded: true)
    identity = "embed-#{@ns}:#{Process.pid}:#{object_id.to_s(16)}"
    launcher.define_singleton_method(:identity) { identity }
    pool = @config.redis_pool

    launcher.heartbeat
    info = Wurk.load_json(pool.with { |c| c.call('HGET', identity, 'info') })

    assert info['embedded'], 'heartbeat info must mark embedded: true'
  ensure
    pool&.with do |c|
      c.call('SREM', Wurk::Keys::PROCESSES, identity)
      c.call('UNLINK', identity, "#{identity}:work", "#{identity}-signals")
    end
  end

  private

  # Embedded over a launcher whose run/stop are the given lambdas — enough to
  # drive the boot-failure paths without spawning manager threads.
  def embedded_with_launcher(run:, stop:)
    embedded = Wurk::Embedded.new(@config)
    stub_redis!(embedded)
    embedded.define_singleton_method(:build_launcher) do
      fake = Object.new
      fake.define_singleton_method(:run) { run.call }
      fake.define_singleton_method(:stop) { stop.call }
      fake
    end
    embedded
  end

  # Skip redis validation AND replace the launcher build with a no-op so
  # we exercise housekeeping/startup/sleep without spawning manager threads.
  def bypass_io(embedded)
    stub_redis!(embedded)
    embedded.define_singleton_method(:build_launcher) do
      fake = Object.new
      def fake.run; end
      fake
    end
    embedded
  end

  def stub_redis!(_embedded)
    fake_pool = Object.new
    fake_pool.define_singleton_method(:info) { { 'redis_version' => '7.2.0', 'maxmemory_policy' => 'noeviction' } }
    @config.define_singleton_method(:redis_pool) { fake_pool }
  end
end
