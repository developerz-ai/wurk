# frozen_string_literal: true

require_relative '../test_helper'

# `wurk boot-check`: #run_swarm's boot without the fork, for CI. The real boot
# against a Rails app is test/integration/boot_check_cli_test.rb; this file
# covers the subcommand seam and what runs, and what never does, after the boot.
class CLIBootCheckCommandTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    Wurk::CLI.reset_instance!
    @out = StringIO.new
    @cli = Wurk::CLI.new
    @cli.config = Wurk::Configuration.new
    @cli.config.logger = ::Logger.new(@out)
    # Nothing listens here: a boot-check that touches Redis without --redis fails.
    @cli.config.redis = { url: 'redis://127.0.0.1:1/0', reconnect_attempts: 0 }
  end

  def teardown
    @cli.config.reset_redis_pools!
    Wurk::CLI.reset_instance!
    Wurk.server = false
    Wurk.worker_boot_claimed = false
  ensure
    super
  end

  def test_boot_check_is_a_command_with_its_own_redis_flag
    parse(%w[boot-check --redis])

    assert_equal 'boot-check', @cli.command
    assert @cli.config[:boot_check_redis]
  end

  def test_the_redis_flag_belongs_to_boot_check_only
    assert_raises(::OptionParser::InvalidOption) { parse(%w[--redis]) }
  end

  def test_boots_the_way_the_swarm_does_then_forks_nothing_and_needs_no_redis
    parse(%w[boot-check])
    order = []
    %i[load_rails_framework preload_bundler_groups boot_application eager_load_application eager_load_rails
       draw_routes].each { |m| @cli.define_singleton_method(m) { order << m } }

    with_no_swarm_or_launcher { assert_equal 0, @cli.run_boot_check }

    assert_equal %i[load_rails_framework preload_bundler_groups boot_application eager_load_application
                    eager_load_rails draw_routes], order
    assert_match(/wurk: boot-check \(as wurkswarm parent\);/, @out.string)
    assert_match(/booted as wurkswarm would/, @out.string)
  end

  def test_runs_the_app_checks_without_redis
    parse(%w[boot-check])
    ran = []
    with_stubbed_boot_checks(ran) { @cli.run_boot_check(boot_app: false) }

    assert_equal [nil], ran
  end

  def test_reads_redis_only_when_asked
    parse(%w[boot-check --redis])
    info = { 'redis_version' => '7.4.0', 'maxmemory_policy' => 'noeviction' }
    @cli.define_singleton_method(:redis_info) { info }
    ran = []
    with_stubbed_boot_checks(ran) { @cli.run_boot_check(boot_app: false) }

    assert_equal [info], ran
  end

  def test_an_undersized_pool_fails_the_check
    parse(%w[boot-check -c 20])
    @cli.config.redis = { url: 'redis://127.0.0.1:1/0', size: 3 }

    error = assert_raises(Wurk::CLI::StartupError) { @cli.run_boot_check(boot_app: false) }

    assert_match(/holds 3 connections, fewer than its concurrency of 20/, error.message)
  end

  # The preload-first retry re-runs the binary that was run, with its command.
  def test_the_preload_first_restart_reruns_wurk_for_a_command
    parse(%w[boot-check])

    assert_equal Wurk::CLI::WURK_EXECUTABLE, @cli.send(:restart_executable)
    assert_equal Wurk::CLI::SWARM_EXECUTABLE, Wurk::CLI.new.send(:restart_executable)
  end

  def test_help_lists_the_command
    parse([])

    assert_includes @cli.send(:option_parser, {}).to_s, 'boot-check Boot the app the way wurkswarm does'
  end

  private

  def parse(args)
    prev = ENV.delete('RAILS_MAX_THREADS')
    @cli.config[:require] = ::File.expand_path('../../lib/wurk.rb', __dir__)
    @cli.parse(args)
  ensure
    ENV['RAILS_MAX_THREADS'] = prev if prev
  end

  def with_stubbed_boot_checks(ran)
    original = Wurk::BootChecks.method(:run)
    Wurk::BootChecks.define_singleton_method(:run) { |_config, info| ran << info }
    yield
  ensure
    Wurk::BootChecks.define_singleton_method(:run, original)
  end

  def with_no_swarm_or_launcher
    swarm_new = Wurk::Swarm.method(:new)
    launcher_new = Wurk::Launcher.method(:new)
    Wurk::Swarm.define_singleton_method(:new) { |*| raise 'boot-check built a swarm' }
    Wurk::Launcher.define_singleton_method(:new) { |*| raise 'boot-check built a launcher' }
    yield
  ensure
    Wurk::Swarm.define_singleton_method(:new, swarm_new)
    Wurk::Launcher.define_singleton_method(:new, launcher_new)
  end
end
