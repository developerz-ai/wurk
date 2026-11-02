# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'
require 'tmpdir'

# The whole runner, real forks, real Redis: a fleet that cannot stay up has to
# become visible to whatever supervises the runner. A parent that respawns
# forever looks Running to an orchestrator and to any process-grep probe.
class SwarmCrashLoopTest < Wurk::Test::UnitCase
  parallelize_me!

  WURKSWARM = ::File.expand_path('../../exe/wurkswarm', __dir__)
  BOUND = 30

  def test_a_fleet_crashing_at_boot_is_reported_and_exits_non_zero
    Dir.mktmpdir do |dir|
      # Long enough for the backoff to deliver three crashes first.
      status, log = run_swarm(dir, 'config.swarm_crash_exit_after = 6; config.on(:startup) { raise "broken release" }')

      assert_equal 1, status.exitstatus
      assert_match(/every swarm slot has crashed/, log)
      assert_match(/crash streak [3-9]/, log, 'a streak should reach ERROR level')
      assert_includes ::File.read(report_path(dir)), 'Wurk::Swarm::CrashLoop'
    end
  end

  def test_a_crash_outside_a_lifecycle_event_reaches_error_handlers
    Dir.mktmpdir do |dir|
      run_swarm(dir, 'Wurk::Launcher.prepend(Module.new { def run(...) = raise("launcher would not boot") })')

      assert_match(/RuntimeError swarm-child-boot/, ::File.read(report_path(dir)))
    end
  end

  def test_a_lifecycle_hook_failure_is_reported_once_per_crash
    Dir.mktmpdir do |dir|
      run_swarm(dir, 'config.on(:startup) { raise "broken release" }')

      refute_match(/swarm-child-boot/, ::File.read(report_path(dir)), 'fire_event already reported it')
    end
  end

  def test_a_redis_outage_alone_does_not_exit_the_swarm
    Dir.mktmpdir do |dir|
      pid, log_path = spawn_swarm(dir, 'config.on(:startup) { raise RedisClient::CannotConnectError, "redis is down" }')

      wait_until { ::File.read(log_path).scan('died (status=75)').size >= 3 }

      refute process_exited?(pid), 'an outage must not end the swarm, however long it lasts'
      refute_match(/every swarm slot has crashed/, ::File.read(log_path))
    ensure
      stop(pid)
    end
  end

  private

  def report_path(dir) = ::File.join(dir, 'reports')

  def app_file(dir, body)
    path = ::File.join(dir, 'app.rb')
    ::File.write(path, <<~RUBY)
      Wurk.configure_server do |config|
        config.redis = { url: #{Wurk::Test.redis_url.inspect} }
        config.swarm_crash_exit_after = 3
        config.error_handlers << lambda { |ex, ctx, _cfg = nil|
          File.write(#{report_path(dir).inspect}, "\#{ex.class} \#{ctx[:context]}\\n", mode: 'a')
        }
        #{body}
      end
    RUBY
    path
  end

  def env = { 'WURK_COUNT' => '1', 'COVERAGE' => nil, 'RUBYOPT' => ENV.fetch('RUBYOPT', nil) }

  def run_swarm(dir, body)
    argv = ['bundle', 'exec', WURKSWARM, '-r', app_file(dir, body), '-c', '1', '-t', '1']
    output = nil
    status = nil
    ::Timeout.timeout(BOUND) { output, status = Open3.capture2e(env, *argv) }
    [status, output]
  end

  def spawn_swarm(dir, body)
    log = ::File.join(dir, 'log')
    argv = ['bundle', 'exec', WURKSWARM, '-r', app_file(dir, body), '-c', '1', '-t', '1']
    [::Process.spawn(env, *argv, %i[out err] => log), log]
  end

  def wait_until(deadline: ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + BOUND)
    until yield
      flunk 'condition not met in time' if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
  end

  def process_exited?(pid)
    !::Process.wait(pid, ::Process::WNOHANG).nil?
  end

  def stop(pid)
    return unless pid

    ::Process.kill('TERM', pid)
    ::Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
