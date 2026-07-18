# frozen_string_literal: true

require_relative '../test_helper'
require 'tempfile'
require 'tmpdir'

# Pure-Ruby CLI surface — option parsing, YAML loading, env detection,
# validation, signal table. The actual `run` / `launch` paths fork the
# process and are covered in test/integration/cli_boot_test.rb.
class CLITest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    Wurk::CLI.reset_instance!
    @cli = Wurk::CLI.new
    @cli.config = Wurk::Configuration.new
    @cli.config.logger = ::Logger.new(IO::NULL)
  end

  def teardown
    Wurk::CLI.reset_instance!
    # The `launch` path flips the process-global `Wurk.server` flag (cli.rb).
    # Reset it so server-mode can't leak into another test class sharing this
    # worker process (e.g. WurkTopLevelTest#test_server_defaults_false).
    Wurk.server = false
  ensure
    super
  end

  # --- shape ----------------------------------------------------------

  def test_aliased_under_sidekiq_namespace
    assert_same Wurk::CLI, Sidekiq::CLI
  end

  def test_includes_component
    assert_includes Wurk::CLI.ancestors, Wurk::Component
  end

  # #191: server mode must be entered so `configure_server` blocks in the
  # booted app actually fire (they gate on `config.server?`). Asserts the
  # per-config gate (deterministic, local to @cli.config) — the process-global
  # `Wurk.server?` side effect is verified in the isolated worker spawned by
  # ConfigureServerBootTest, where a sibling test's teardown can't race it.
  def test_enter_server_mode_opens_the_configure_server_gate
    refute_predicate @cli.config, :server?, 'precondition: not yet in server mode'

    @cli.send(:enter_server_mode)

    assert_predicate @cli.config, :server?, 'config.server? gates configure_server — must be true'

    yielded = false
    @cli.config.configure_server { yielded = true }

    assert yielded, 'configure_server must fire once server mode is entered'
  end

  def test_wurk_enter_server_mode_sets_server_flag_on_given_config
    config = Wurk::Configuration.new

    Wurk.enter_server_mode(config)

    assert config[:server], 'enter_server_mode must open the per-config gate'
  end

  def test_instance_is_memoized_singleton
    a = Wurk::CLI.instance
    b = Wurk::CLI.instance

    assert_same a, b
  end

  def test_reset_instance_drops_cache
    a = Wurk::CLI.instance
    Wurk::CLI.reset_instance!
    b = Wurk::CLI.instance

    refute_same a, b
  end

  def test_signal_handlers_table
    assert_equal %w[INT TERM TSTP TTIN INFO USR2].sort, Wurk::CLI::SIGNAL_HANDLERS.keys.sort
  end

  def test_min_redis_version
    assert_equal '7.0.0', Wurk::CLI::MIN_REDIS_VERSION
  end

  # --- option parsing -------------------------------------------------

  def test_parse_concurrency_flag
    with_require_set { @cli.parse(%w[-c 12 -q default]) }

    assert_equal 12, @cli.config[:concurrency]
  end

  def test_parse_queue_flag_repeatable
    with_require_set { @cli.parse(%w[-q critical,3 -q default]) }

    assert_equal %w[critical default], @cli.config.default_capsule.weights.keys
  end

  def test_parse_environment_flag_overrides_env
    prev = ENV.fetch('RAILS_ENV', nil)
    ENV['RAILS_ENV'] = 'staging'
    with_require_set { @cli.parse(%w[-e production -q default]) }

    assert_equal 'production', @cli.environment
  ensure
    prev.nil? ? ENV.delete('RAILS_ENV') : ENV['RAILS_ENV'] = prev
  end

  def test_environment_defaults_to_development
    prev_app = ENV.fetch('APP_ENV', nil)
    prev_rails = ENV.fetch('RAILS_ENV', nil)
    prev_rack = ENV.fetch('RACK_ENV', nil)
    ENV.delete('APP_ENV')
    ENV.delete('RAILS_ENV')
    ENV.delete('RACK_ENV')
    with_require_set { @cli.parse(%w[-q default]) }

    assert_equal 'development', @cli.environment
  ensure
    ENV['APP_ENV'] = prev_app if prev_app
    ENV['RAILS_ENV'] = prev_rails if prev_rails
    ENV['RACK_ENV'] = prev_rack if prev_rack
  end

  def test_parse_tag_flag
    with_require_set { @cli.parse(%w[-g billing -q default]) }

    assert_equal 'billing', @cli.config[:tag]
  end

  def test_parse_timeout_flag
    with_require_set { @cli.parse(%w[-t 60 -q default]) }

    assert_equal 60, @cli.config[:timeout]
  end

  def test_parse_verbose_sets_debug_level
    with_require_set do
      @cli.parse(%w[-v -q default])
    end

    assert_equal ::Logger::DEBUG, @cli.config.logger.level
  end

  def test_parse_version_exits
    assert_raises(SystemExit) { capture_io { @cli.parse(['-V']) } }
  end

  def test_parse_help_exits
    assert_raises(SystemExit) { capture_io { @cli.parse(['-h']) } }
  end

  # --- YAML / ERB config loader ---------------------------------------

  def test_loads_yaml_config_via_dash_c
    Tempfile.create(['wurk', '.yml']) do |f|
      f.write(<<~YAML)
        :concurrency: 7
        :queues:
          - critical
          - default
      YAML
      f.flush
      with_require_set { @cli.parse(['-C', f.path]) }

      assert_equal 7, @cli.config[:concurrency]
      assert_includes @cli.config.default_capsule.weights.keys, 'critical'
    end
  end

  # #241: a real sidekiq.yml writes weighted queues as nested arrays
  # (`- [critical, 2]`). YAML parses those to `["critical", 2]`, which used to
  # crash the CLI at boot with `invalid value for Integer(): " 2]"`.
  def test_loads_yaml_with_sidekiq_weighted_queue_arrays
    Tempfile.create(['wurk', '.yml']) do |f|
      f.write(<<~YAML)
        :concurrency: 5
        :queues:
          - [critical, 2]
          - [default, 1]
      YAML
      f.flush
      with_require_set { @cli.parse(['-C', f.path]) }

      assert_equal({ 'critical' => 2, 'default' => 1 }, @cli.config.default_capsule.weights)
    end
  end

  def test_loads_erb_config
    Tempfile.create(['wurk', '.yml.erb']) do |f|
      f.write(":concurrency: <%= 4 + 1 %>\n:queues:\n  - default\n")
      f.flush
      with_require_set { @cli.parse(['-C', f.path]) }

      assert_equal 5, @cli.config[:concurrency]
    end
  end

  def test_yaml_environment_overlay_applied
    Tempfile.create(['wurk', '.yml']) do |f|
      f.write(<<~YAML)
        :concurrency: 2
        :queues:
          - default
        :production:
          :concurrency: 25
      YAML
      f.flush
      with_require_set { @cli.parse(['-C', f.path, '-e', 'production']) }

      assert_equal 25, @cli.config[:concurrency]
    end
  end

  def test_yaml_capsules_create_named_capsules
    Tempfile.create(['wurk', '.yml']) do |f|
      f.write(<<~YAML)
        :concurrency: 2
        :queues:
          - default
        :capsules:
          billing:
            :concurrency: 3
            :queues:
              - invoices
      YAML
      f.flush
      with_require_set { @cli.parse(['-C', f.path]) }

      cap = @cli.config.capsules['billing']

      assert_equal 3, cap.concurrency
      assert_includes cap.queues, 'invoices'
    end
  end

  # lines 215 else + 216 else — a capsule block with neither :queues nor
  # :concurrency leaves the named capsule's defaults untouched.
  def test_yaml_capsule_without_queues_or_concurrency_keeps_defaults
    parse_yaml(<<~YAML)
      :concurrency: 2
      :queues:
        - default
      :capsules:
        billing:
          :foo: bar
    YAML
    cap = @cli.config.capsules['billing']
    default_cap = Wurk::Capsule.new('billing', @cli.config)

    assert_equal default_cap.concurrency, cap.concurrency
    assert_equal default_cap.queues, cap.queues
  end

  # line 239 else — `parse_config` called with no environment set skips the
  # overlay-delete entirely.
  def test_parse_config_without_environment_skips_overlay
    Tempfile.create(['wurk', '.yml']) do |f|
      f.write(<<~YAML)
        :concurrency: 4
        :production:
          :concurrency: 99
      YAML
      f.flush
      @cli.instance_variable_set(:@environment, nil)
      opts = @cli.send(:parse_config, f.path)

      assert_equal 4, opts[:concurrency]
      # Overlay key is left intact because no environment was selected.
      assert_equal 99, opts[:production][:concurrency]
    end
  end

  # line 247 else — an Integer key does not respond to #to_sym, so
  # symbolize_keys_deep! leaves it as-is.
  def test_symbolize_keys_deep_leaves_non_symbolizable_keys
    refute_respond_to(1, :to_sym)
    hash = { 1 => 'value', 'nested' => { 2 => 'x' } }

    @cli.send(:symbolize_keys_deep!, hash)

    assert_equal 'value', hash[1]
    assert_equal 'x', hash[:nested][2]
  end

  def test_missing_config_file_raises
    assert_raises(ArgumentError) do
      with_require_set { @cli.parse(['-C', '/does/not/exist.yml']) }
    end
  end

  def test_autodiscovers_wurk_yml_in_require_dir
    Dir.mktmpdir do |dir|
      Dir.mkdir(::File.join(dir, 'config'))
      File.write(::File.join(dir, 'config', 'wurk.yml'), ":concurrency: 9\n:queues:\n  - default\n")
      File.write(::File.join(dir, 'config', 'application.rb'), '# noop')
      @cli.parse(['-r', dir])

      assert_equal 9, @cli.config[:concurrency]
    end
  end

  # --- validation -----------------------------------------------------

  def test_validate_dies_when_require_missing
    @cli.config[:require] = '/totally/missing/path'
    assert_raises(SystemExit) { capture_io { @cli.parse(['-q', 'default']) } }
  end

  def test_validate_dies_when_dir_lacks_application_rb
    Dir.mktmpdir do |dir|
      @cli.config[:require] = dir
      assert_raises(SystemExit) { capture_io { @cli.parse(['-q', 'default']) } }
    end
  end

  # line 199 else — when :concurrency is already set, apply_defaults! returns
  # before consulting RAILS_MAX_THREADS.
  def test_apply_defaults_keeps_explicit_concurrency
    prev = ENV.fetch('RAILS_MAX_THREADS', nil)
    ENV['RAILS_MAX_THREADS'] = '50'
    opts = { concurrency: 8 }
    @cli.send(:apply_defaults!, opts)

    assert_equal 8, opts[:concurrency]
    assert_equal ['default'], opts[:queues]
  ensure
    prev.nil? ? ENV.delete('RAILS_MAX_THREADS') : ENV['RAILS_MAX_THREADS'] = prev
  end

  # line 199 else (second arm) — no explicit concurrency and no
  # RAILS_MAX_THREADS leaves concurrency unset.
  def test_apply_defaults_no_rails_max_threads_leaves_concurrency_nil
    prev = ENV.fetch('RAILS_MAX_THREADS', nil)
    ENV.delete('RAILS_MAX_THREADS')
    opts = {}
    @cli.send(:apply_defaults!, opts)

    assert_nil opts[:concurrency]
  ensure
    ENV['RAILS_MAX_THREADS'] = prev if prev
  end

  # line 182 else — validate_pool_sizes! returns cleanly when every capsule's
  # real Redis pool is at least as large as its concurrency.
  def test_validate_pool_sizes_passes_when_pool_large_enough
    @cli.config.redis = { url: Wurk::Test.redis_url }
    @cli.config.reset_redis_pools!
    cap = @cli.config.default_capsule
    cap.concurrency = 1

    assert_operator(cap.redis_pool.size, :>=, cap.concurrency)
    @cli.send(:validate_pool_sizes!) # does not raise
  ensure
    @cli.config.reset_redis_pools!
  end

  def test_validate_raises_on_non_positive_concurrency
    with_require_set { @cli.parse(['-q', 'default']) }
    @cli.config[:concurrency] = 0
    assert_raises(ArgumentError) { @cli.send(:validate!) }
  end

  # --- signal table ---------------------------------------------------

  def test_handle_signal_tstp_quiets_launcher
    with_require_set { @cli.parse(['-q', 'default']) }
    stub = Class.new do
      attr_reader :quiet_called

      def quiet
        @quiet_called = true
      end
    end.new
    @cli.launcher = stub

    @cli.handle_signal('TSTP')

    assert stub.quiet_called
  end

  def test_handle_signal_int_raises_interrupt
    assert_raises(Interrupt) { @cli.handle_signal('INT') }
  end

  def test_handle_signal_term_raises_interrupt
    assert_raises(Interrupt) { @cli.handle_signal('TERM') }
  end

  def test_handle_signal_unknown_logs_and_does_not_raise
    @cli.handle_signal('WINCH')
  end

  def test_handle_signal_info_dumps_thread_backtraces
    io = StringIO.new
    @cli.config.logger = ::Logger.new(io)
    @cli.handle_signal('INFO')

    assert_match(/Thread TID-/, io.string)
  end

  # line 35 else — a thread whose `backtrace` is nil hits the
  # `<no backtrace available>` branch of BACKTRACE_DUMPER. A real thread's
  # backtrace nilness is a transient VM state we can't pin deterministically,
  # so we feed Thread.list a fake thread with no backtrace for the call.
  def test_handle_signal_info_reports_missing_backtrace
    io = StringIO.new
    @cli.config.logger = ::Logger.new(io)
    fake = Object.new
    fake.define_singleton_method(:name) { 'no-bt' }
    fake.define_singleton_method(:backtrace) { nil }

    original = Thread.method(:list)
    Thread.define_singleton_method(:list) { [fake] }
    begin
      @cli.handle_signal('INFO')
    ensure
      Thread.define_singleton_method(:list, original)
    end

    assert_match(/<no backtrace available>/, io.string)
  end

  # USR2 reopens the logs for logrotate. reopen_logs is private, so the handler
  # must reach it via __send__ — a plain `cli.reopen_logs` raises NoMethodError
  # and log rotation silently breaks.
  def test_handle_signal_usr2_reopens_logs
    reopened = false
    logger = ::Logger.new(IO::NULL)
    logger.define_singleton_method(:reopen) { reopened = true }
    @cli.config.logger = logger

    @cli.handle_signal('USR2')

    assert reopened, 'USR2 must reopen the logs despite reopen_logs being private'
  end

  # --- run plumbing (without booting Redis/launcher) -----------------

  def test_run_short_circuits_when_redis_too_old
    with_require_set { @cli.parse(['-q', 'default']) }
    @cli.define_singleton_method(:redis_info) { { 'redis_version' => '6.2.0', 'maxmemory_policy' => 'noeviction' } }
    @cli.define_singleton_method(:trap_signals) { |_| nil }
    err = assert_raises(RuntimeError) { @cli.run(boot_app: false, warmup: false) }

    assert_match(/Redis 7\.0\.0 or greater/, err.message)
  end

  def test_run_warns_on_non_noeviction_policy
    with_require_set { @cli.parse(['-q', 'default']) }
    io = StringIO.new
    @cli.config.logger = ::Logger.new(io)
    @cli.define_singleton_method(:redis_info) { { 'redis_version' => '7.2.0', 'maxmemory_policy' => 'allkeys-lru' } }
    @cli.define_singleton_method(:trap_signals) { |_| nil }
    @cli.define_singleton_method(:validate_pool_sizes!) { nil }
    @cli.define_singleton_method(:launch) { |_self_read| nil }
    @cli.run(boot_app: false, warmup: false)

    assert_match(/will evict Wurk data/, io.string)
  end

  def test_run_raises_when_pool_size_under_concurrency
    with_require_set { @cli.parse(['-q', 'default']) }
    @cli.define_singleton_method(:redis_info) { { 'redis_version' => '7.2.0', 'maxmemory_policy' => 'noeviction' } }
    @cli.define_singleton_method(:trap_signals) { |_| nil }
    cap = @cli.config.default_capsule
    cap.concurrency = 999
    fake_pool = Object.new
    fake_pool.define_singleton_method(:size) { 1 }
    cap.define_singleton_method(:redis_pool) { fake_pool }
    err = assert_raises(ArgumentError) { @cli.run(boot_app: false, warmup: false) }

    assert_match(/Pool size too small/, err.message)
  end

  # line 96 then + line 105 then — boot_app:true runs boot_application and
  # warmup:true reaches the Process.warmup guard. We point :require at a real
  # single .rb file and stub the Redis/launch tail so nothing actually boots.
  def test_run_boots_app_and_warms_up
    booted = []
    @cli.define_singleton_method(:boot_application) { booted << :boot }
    @cli.define_singleton_method(:redis_info) { { 'redis_version' => '7.2.0', 'maxmemory_policy' => 'noeviction' } }
    @cli.define_singleton_method(:trap_signals) { |_| nil }
    @cli.define_singleton_method(:validate_pool_sizes!) { nil }
    @cli.define_singleton_method(:identity) { 'host:1:abc' }
    @cli.define_singleton_method(:launch) { |_self_read| booted << :launch }

    without_warmup_disable { @cli.run(boot_app: true, warmup: true) }

    assert_equal %i[boot launch], booted
  end

  # lines 128 then/body + 129 then/else — drive launch's self-pipe loop with a
  # real pipe: one signal line (handled), then EOF (gets returns nil → break).
  def test_launch_loop_handles_signal_then_breaks_on_nil
    with_require_set { @cli.parse(['-q', 'default']) }
    seen = []
    @cli.define_singleton_method(:handle_signal) { |sig| seen << sig }

    self_read, self_write = IO.pipe
    self_write.puts('TTIN')
    self_write.close # EOF → next gets returns nil → break (line 129 then)

    fake_launcher = Object.new
    fake_launcher.define_singleton_method(:run) { nil }

    with_stub_launcher(fake_launcher) { @cli.send(:launch, self_read) }

    assert_equal ['TTIN'], seen
  ensure
    self_read&.close
  end

  # line 128 else / rescue path — an Interrupt inside the loop triggers the
  # graceful-shutdown rescue, which calls launcher.stop and exits(0).
  def test_launch_rescues_interrupt_and_exits
    with_require_set { @cli.parse(['-q', 'default']) }
    stopped = []
    fake_launcher = Object.new
    fake_launcher.define_singleton_method(:run) { nil }
    fake_launcher.define_singleton_method(:stop) { stopped << :stop }
    @cli.define_singleton_method(:handle_signal) { |_sig| raise Interrupt }

    self_read, self_write = IO.pipe
    self_write.puts('INT')

    with_stub_launcher(fake_launcher) do
      assert_raises(SystemExit) { @cli.send(:launch, self_read) }
    end

    assert_equal [:stop], stopped
  ensure
    self_read&.close
    self_write&.close
  end

  # --- boot_application paths -----------------------------------------

  def test_boot_application_requires_single_file
    Dir.mktmpdir do |dir|
      sentinel = ::File.join(dir, 'sentinel.rb')
      File.write(sentinel, 'BOOTED = :ok')
      @cli.config[:require] = sentinel
      @cli.instance_variable_set(:@environment, 'test')

      @cli.send(:boot_application)

      assert(defined?(BOOTED))
    end
  end

  # line 309 then — when :require points at a directory, boot_application
  # dispatches to boot_rails_application. We stub that tail because actually
  # booting Rails (require 'rails' + config/environment.rb) mutates global
  # process state irreversibly and is exercised in the engine suite instead.
  def test_boot_application_dispatches_to_rails_for_directory
    Dir.mktmpdir do |dir|
      @cli.config[:require] = dir
      @cli.instance_variable_set(:@environment, 'test')
      dispatched = []
      @cli.define_singleton_method(:boot_rails_application) { |path| dispatched << path }

      @cli.send(:boot_application)

      assert_equal [dir], dispatched
    end
  end

  # Regression #253: standalone mode never loads the engine, so the ActiveJob
  # `:wurk` adapter it normally defines is absent and a `queue_adapter = :wurk`
  # app crashes with `uninitialized constant WurkAdapter` while booting. The CLI
  # must define the adapter itself. Forked so removing the already-loaded
  # constant + its $LOADED_FEATURES entry (to simulate the engine-absent state)
  # can't leak into sibling suites; the child exits 0 only if the adapter is
  # (re)defined.
  def test_define_active_job_adapter_defines_wurk_adapter_standalone
    adapter_path = ::File.expand_path('../../lib/active_job/queue_adapters/wurk_adapter.rb', __dir__)
    pid = ::Process.fork do
      require 'active_job'
      $LOADED_FEATURES.delete(adapter_path)
      qa = ActiveJob::QueueAdapters
      qa.send(:remove_const, :WurkAdapter) if qa.const_defined?(:WurkAdapter, false)

      @cli.send(:define_active_job_adapter)

      exit(qa.const_defined?(:WurkAdapter, false) ? 0 : 1)
    end
    _, status = ::Process.wait2(pid)

    assert_predicate status, :success?,
                     'standalone CLI must define ActiveJob::QueueAdapters::WurkAdapter (#253)'
  end

  # --- swarm preload knobs (Ent §7.2) ---------------------------------

  def test_preload_groups_defaults_to_default_group
    with_env('WURK_PRELOAD' => nil, 'SIDEKIQ_PRELOAD' => nil) do
      assert_equal [:default], @cli.send(:preload_groups)
    end
  end

  def test_preload_groups_parses_comma_list_and_strips_blanks
    with_env('WURK_PRELOAD' => ' default , assets ,', 'SIDEKIQ_PRELOAD' => nil) do
      assert_equal %i[default assets], @cli.send(:preload_groups)
    end
  end

  def test_preload_groups_native_env_wins_over_sidekiq_alias
    with_env('WURK_PRELOAD' => 'web', 'SIDEKIQ_PRELOAD' => 'worker') do
      assert_equal [:web], @cli.send(:preload_groups)
    end
  end

  def test_preload_groups_falls_back_to_sidekiq_alias
    with_env('WURK_PRELOAD' => nil, 'SIDEKIQ_PRELOAD' => 'worker') do
      assert_equal [:worker], @cli.send(:preload_groups)
    end
  end

  def test_preload_groups_empty_value_disables
    with_env('WURK_PRELOAD' => '', 'SIDEKIQ_PRELOAD' => nil) do
      assert_empty @cli.send(:preload_groups)
    end
  end

  def test_preload_bundler_groups_requires_configured_groups
    with_env('WURK_PRELOAD' => 'default,assets', 'SIDEKIQ_PRELOAD' => nil) do
      with_stub_bundler_require do |calls|
        @cli.send(:preload_bundler_groups)

        assert_equal [%i[default assets]], calls
      end
    end
  end

  def test_preload_bundler_groups_empty_value_skips_require
    with_env('WURK_PRELOAD' => '', 'SIDEKIQ_PRELOAD' => nil) do
      with_stub_bundler_require do |calls|
        @cli.send(:preload_bundler_groups)

        assert_empty calls
      end
    end
  end

  def test_preload_app_true_for_native_or_alias
    with_env('WURK_PRELOAD_APP' => '1', 'SIDEKIQ_PRELOAD_APP' => nil) do
      assert @cli.send(:preload_app?)
    end
    with_env('WURK_PRELOAD_APP' => nil, 'SIDEKIQ_PRELOAD_APP' => '1') do
      assert @cli.send(:preload_app?)
    end
  end

  def test_preload_app_native_zero_overrides_alias_and_default_false
    with_env('WURK_PRELOAD_APP' => '0', 'SIDEKIQ_PRELOAD_APP' => '1') do
      refute @cli.send(:preload_app?), 'native WURK_PRELOAD_APP=0 must override the alias'
    end
    with_env('WURK_PRELOAD_APP' => nil, 'SIDEKIQ_PRELOAD_APP' => nil) do
      refute @cli.send(:preload_app?)
    end
  end

  def test_eager_load_application_eager_loads_when_enabled
    loaded = []
    fake_app = Object.new
    fake_app.define_singleton_method(:eager_load!) { loaded << :loaded }
    with_env('WURK_PRELOAD_APP' => '1', 'SIDEKIQ_PRELOAD_APP' => nil) do
      @cli.define_singleton_method(:rails_application) { fake_app }
      @cli.send(:eager_load_application)
    end

    assert_equal [:loaded], loaded
  end

  def test_eager_load_application_noop_when_disabled
    loaded = []
    fake_app = Object.new
    fake_app.define_singleton_method(:eager_load!) { loaded << :loaded }
    with_env('WURK_PRELOAD_APP' => nil, 'SIDEKIQ_PRELOAD_APP' => nil) do
      @cli.define_singleton_method(:rails_application) { fake_app }
      @cli.send(:eager_load_application)
    end

    assert_empty loaded
  end

  def test_eager_load_application_noop_without_rails_application
    with_env('WURK_PRELOAD_APP' => '1', 'SIDEKIQ_PRELOAD_APP' => nil) do
      @cli.define_singleton_method(:rails_application) { nil }

      assert_nil @cli.send(:eager_load_application)
    end
  end

  # rails_application reflects whether Rails is loaded in this worker; assert the
  # branch that matches the current process rather than forcing a global ::Rails.
  def test_rails_application_reflects_rails_presence
    result = @cli.send(:rails_application)
    if defined?(::Rails) && ::Rails.respond_to?(:application)
      assert_equal ::Rails.application, result
    else
      assert_nil result
    end
  end

  def test_run_swarm_preloads_then_boots_then_eager_loads
    order = []
    @cli.define_singleton_method(:preload_bundler_groups) { order << :preload }
    @cli.define_singleton_method(:boot_application) { order << :boot }
    @cli.define_singleton_method(:eager_load_application) { order << :eager }
    @cli.define_singleton_method(:validate_redis!) { nil }
    @cli.define_singleton_method(:validate_pool_sizes!) { nil }
    @cli.define_singleton_method(:identity) { 'host:1:abc' }
    fake_swarm = Object.new
    fake_swarm.define_singleton_method(:boot) { |**| nil }
    fake_swarm.define_singleton_method(:supervise) { order << :supervise }

    with_stub_swarm(fake_swarm) { @cli.run_swarm(boot_app: true, warmup: false) }

    assert_equal %i[preload boot eager supervise], order
  end

  def test_run_swarm_skips_boot_steps_when_boot_app_false
    called = []
    %i[preload_bundler_groups boot_application eager_load_application].each do |m|
      @cli.define_singleton_method(m) { called << m }
    end
    @cli.define_singleton_method(:validate_redis!) { nil }
    @cli.define_singleton_method(:validate_pool_sizes!) { nil }
    @cli.define_singleton_method(:identity) { 'host:1:abc' }
    fake_swarm = Object.new
    fake_swarm.define_singleton_method(:boot) { |**| nil }
    fake_swarm.define_singleton_method(:supervise) { nil }

    with_stub_swarm(fake_swarm) { @cli.run_swarm(boot_app: false, warmup: false) }

    assert_empty called
  end

  private

  # `validate!` requires `:require` to point at a real file (or a Rails dir
  # with `config/application.rb`). Use the gem's own lib/wurk.rb — it's a
  # file, so we skip the Rails-shape check entirely.
  def with_require_set
    prev = ENV.fetch('RAILS_MAX_THREADS', nil)
    ENV.delete('RAILS_MAX_THREADS')
    @cli.config[:require] = ::File.expand_path('../../lib/wurk.rb', __dir__)
    yield
  ensure
    ENV['RAILS_MAX_THREADS'] = prev if prev
  end

  # Write `body` to a temp YAML file and drive `parse -C` against it.
  def parse_yaml(body)
    Tempfile.create(['wurk', '.yml']) do |f|
      f.write(body)
      f.flush
      with_require_set { @cli.parse(['-C', f.path]) }
    end
  end

  # `Process.warmup` is gated on RUBY_DISABLE_WARMUP != '1'; clear it so the
  # warmup branch is reachable, then restore.
  def without_warmup_disable
    prev = ENV.fetch('RUBY_DISABLE_WARMUP', nil)
    ENV.delete('RUBY_DISABLE_WARMUP')
    yield
  ensure
    prev.nil? ? ENV.delete('RUBY_DISABLE_WARMUP') : ENV['RUBY_DISABLE_WARMUP'] = prev
  end

  # minitest 6 dropped Object#stub, so swap Wurk::Launcher.new for a fake via a
  # temporary singleton method and restore it after. parallel_fork forks per
  # class, so this never leaks into sibling suites.
  def with_stub_launcher(fake)
    original = Wurk::Launcher.method(:new)
    Wurk::Launcher.define_singleton_method(:new) { |*, **| fake }
    yield
  ensure
    Wurk::Launcher.define_singleton_method(:new, original)
  end

  def with_stub_swarm(fake)
    original = Wurk::Swarm.method(:new)
    Wurk::Swarm.define_singleton_method(:new) { |*, **| fake }
    yield
  ensure
    Wurk::Swarm.define_singleton_method(:new, original)
  end

  # Capture the groups passed to Bundler.require without actually loading gems.
  def with_stub_bundler_require
    calls = []
    original = ::Bundler.method(:require)
    ::Bundler.define_singleton_method(:require) { |*groups| calls << groups }
    yield calls
  ensure
    ::Bundler.define_singleton_method(:require, original)
  end

  # Set the given ENV vars (nil = unset) for the block, then restore the prior
  # values. Mirrors the per-test save/restore the rest of this suite uses.
  def with_env(vars)
    prev = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    prev.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
