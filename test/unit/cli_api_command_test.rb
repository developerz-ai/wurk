# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api'

# Slice 07, task 48 — `wurk api`, the CLI's first subcommand: mount mode 3,
# the machine HTTP API served standalone with no Rails and no worker. The
# worker's own option surface is covered in cli_test.rb; this file speaks only
# about the subcommand seam and what run_api does with it.
class CLIApiCommandTest < Wurk::Test::UnitCase
  parallelize_me!

  TOKEN = 'cli-api-command-test-token-0123456789'

  def setup
    super
    Wurk::CLI.reset_instance!
    @cli = Wurk::CLI.new
    @cli.config = Wurk::Configuration.new
    @cli.config.logger = ::Logger.new(IO::NULL)
    @cli.config.redis = { url: Wurk::Test.redis_url }
  end

  def teardown
    Wurk::CLI.reset_instance!
    # run_api flips the process-global `Wurk.server` flag, same as the worker
    # runner — reset it so server mode can't leak into a sibling test class
    # sharing this worker process.
    Wurk.server = false
  ensure
    super
  end

  # --- the subcommand seam ---------------------------------------------

  def test_bare_wurk_names_no_command
    parse([])

    assert_nil @cli.command
  end

  def test_api_is_recognized_as_the_first_argument
    parse(%w[api])

    assert_equal 'api', @cli.command
  end

  # The command is pulled off argv before OptionParser runs, so the flags that
  # follow it are parsed as flags rather than left behind as stray arguments.
  def test_the_command_is_consumed_before_its_flags_are_parsed
    args = %w[api --port 9999]
    parse(args)

    assert_empty args
    assert_equal 9999, @cli.config[:api_port]
  end

  def test_a_word_that_names_no_command_is_not_taken_as_one
    parse(%w[--queue default])

    assert_nil @cli.command
  end

  def test_api_flags_are_offered_only_to_the_api_command
    assert_raises(::OptionParser::InvalidOption) { parse(%w[--port 9999]) }
  end

  def test_the_banner_names_the_command_being_run
    parse(%w[api])

    assert_includes @cli.send(:option_parser, {}).banner, 'wurk api [options]'
  end

  def test_the_bare_banner_is_unchanged
    parse([])

    assert_includes @cli.send(:option_parser, {}).banner, 'wurk [options]'
  end

  def test_bind_port_and_server_are_all_parseable
    parse(%w[api --bind 127.0.0.1 --port 8080 --server puma])

    assert_equal '127.0.0.1', @cli.config[:api_bind]
    assert_equal 8080, @cli.config[:api_port]
    assert_equal 'puma', @cli.config[:api_server]
  end

  # The swarm binaries take no subcommand. Silently booting a job-consuming
  # swarm for someone who asked for an API server is the worst answer here.
  #
  # The pinned one-connection pool is a backstop, not part of the claim: it
  # makes the very next check (`validate_pool_sizes!`) raise, so a regression
  # that drops the guard fails this test on the message instead of forking a
  # real swarm and supervising it forever.
  def test_the_swarm_runner_refuses_a_subcommand
    @cli.config.redis = { url: Wurk::Test.redis_url, size: 1 }
    @cli.config.default_capsule.concurrency = 5
    parse(%w[api])

    error = assert_raises(ArgumentError) { @cli.run_swarm(boot_app: false, warmup: false) }

    assert_match(/no subcommand/, error.message)
  end

  # --- run_api ----------------------------------------------------------

  def test_run_api_serves_the_same_rack_app_every_other_mount_does
    @cli.config.api_token(TOKEN, scopes: %i[read])
    handler = RecordingHandler.new

    @cli.run_api(boot_app: false, handler: handler)

    assert_same Wurk::API, handler.app, 'standalone must serve the module a config.ru would run'
  end

  def test_run_api_binds_every_interface_on_7433_by_default
    @cli.config.api_token(TOKEN, scopes: %i[read])
    handler = RecordingHandler.new

    @cli.run_api(boot_app: false, handler: handler)

    assert_equal '0.0.0.0', handler.options[:Host]
    assert_equal 7433, handler.options[:Port]
  end

  def test_run_api_binds_where_the_flags_said
    @cli.config.api_token(TOKEN, scopes: %i[read])
    parse(%w[api --bind 127.0.0.1 --port 8080])
    handler = RecordingHandler.new

    @cli.run_api(boot_app: false, handler: handler)

    assert_equal '127.0.0.1', handler.options[:Host]
    assert_equal 8080, handler.options[:Port]
  end

  # Same reason #run does it: `configure_server` blocks gate on `config.server?`,
  # so a host that registers its credential in one would otherwise serve an API
  # with no token at all. Stands in for the app `-r` loads — the block only
  # fires if server mode was entered before the app booted.
  def test_run_api_enters_server_mode_before_booting_the_app
    handler = RecordingHandler.new
    def @cli.boot_application
      config.configure_server { |config| config.api_token(TOKEN, scopes: %i[read]) }
    end

    @cli.run_api(handler: handler)

    assert_equal %i[read], @cli.config.api_tokens[TOKEN], 'configure_server must have fired'
    assert_same Wurk::API, handler.app
  end

  # Binding a port that answers 404 to everything is not a server, it is a
  # misconfiguration an operator would have to diagnose over HTTP.
  def test_run_api_refuses_to_serve_with_no_token_registered
    handler = RecordingHandler.new

    error = assert_raises(ArgumentError) { @cli.run_api(boot_app: false, handler: handler) }

    assert_match(/No API token is registered/, error.message)
    assert_match(/api_token/, error.message)
    assert_nil handler.app, 'nothing may be served'
  end

  # --- handler resolution ------------------------------------------------

  # Neither rack 2's handlers nor rack 3's `rackup` gem are wurk dependencies:
  # the web server is the host's choice. Say which gem is missing rather than
  # letting a bare LoadError out.
  def test_an_unresolvable_handler_names_the_fix
    error = assert_raises(ArgumentError) { @cli.send(:api_handler, 'no-such-web-server') }

    assert_match(/could not start a web server/, error.message)
    assert_match(/puma/, error.message)
  end

  def test_a_named_handler_is_resolved_through_the_installed_registry
    registry = @cli.send(:handler_registry)

    assert_respond_to registry, :get
    assert_respond_to registry, :default
  end

  private

  # Stands in for Rackup::Handler::Puma and friends: records what it was asked
  # to serve instead of binding a socket.
  class RecordingHandler
    attr_reader :app, :options

    def run(app, **options)
      @app = app
      @options = options
    end
  end

  def parse(args)
    @cli.config[:require] = ::File.expand_path('../../lib/wurk.rb', __dir__)
    @cli.parse(args)
  end
end
