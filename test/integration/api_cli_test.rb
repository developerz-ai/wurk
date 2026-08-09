# frozen_string_literal: true

require_relative '../test_helper'
require 'English'
require 'timeout'

# Slice 07, task 48 — `wurk api` driven through the real binary, in a real
# subprocess: the entry point mount mode 3 actually ships as. The option
# surface itself is unit-tested in test/unit/cli_api_command_test.rb; what only
# a spawned process can prove is that exe/wurk dispatches the subcommand to
# run_api instead of the worker runner, and that the swarm binaries refuse it.
class ApiCliTest < Wurk::Test::UnitCase
  parallelize_me!

  # Requiring the gem's own entrypoint is a no-op — it is already loaded by the
  # time boot_application runs — but it satisfies `-r`, which every wurk
  # invocation needs, without a fixture app.
  ENTRYPOINT = ::File.expand_path('../../lib/wurk.rb', __dir__)

  CLI_TIMEOUT = 30

  def test_the_api_subcommand_documents_its_own_flags
    output, status = run_cli('wurk', 'api', '--help')

    assert_equal 0, status
    assert_includes output, 'wurk api [options]'
    assert_includes output, '--port'
    assert_includes output, '--bind'
  end

  # The worker's help stays the worker's: a flag that only means something to
  # the API server has no business in it.
  def test_the_worker_help_does_not_offer_the_api_flags
    output, status = run_cli('wurk', '--help')

    assert_equal 0, status
    assert_includes output, 'wurk [options]'
    refute_includes output, '--port'
  end

  # The dispatch proof. Only run_api refuses to start over a missing token —
  # the worker runner would have gone on to build a Launcher and block.
  def test_the_binary_dispatches_the_subcommand_to_the_api_runner
    output, status = run_cli('wurk', 'api', '-r', ENTRYPOINT)

    refute_equal 0, status
    assert_includes output, 'No API token is registered'
  end

  def test_the_swarm_binary_refuses_the_subcommand
    output, status = run_cli('wurkswarm', 'api', '-r', ENTRYPOINT)

    refute_equal 0, status
    assert_includes output, 'takes no subcommand'
    assert_includes output, 'wurk api'
  end

  private

  # Runs the shipped binary the way an operator does, under this suite's bundle
  # and this worker's Redis DB. Bounded because every command here is supposed
  # to exit on its own: a dispatch regression that lands `wurk api` in the
  # worker runner blocks forever, and that has to fail this test rather than
  # hang the suite.
  def run_cli(binary, *args)
    exe = ::File.expand_path("../../exe/#{binary}", __dir__)
    io = ::IO.popen({ 'REDIS_URL' => Wurk::Test.redis_url }, [RbConfig.ruby, exe, *args], err: %i[child out])
    begin
      output = ::Timeout.timeout(CLI_TIMEOUT) { io.read }
    rescue ::Timeout::Error
      ::Process.kill('KILL', io.pid)

      flunk "#{binary} #{args.join(' ')} never exited within #{CLI_TIMEOUT}s"
    ensure
      io.close
    end
    [output, $CHILD_STATUS.exitstatus]
  end
end
