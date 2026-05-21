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
    assert_equal %w[INT TERM TSTP TTIN INFO].sort, Wurk::CLI::SIGNAL_HANDLERS.keys.sort
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
end
