# frozen_string_literal: true

require_relative '../test_helper'

# examples/wurk.service and examples/capistrano/wurk.rake are pasted into
# production as they are: the timings and hooks must agree with the runner.
class ExamplesOpsTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../../examples', __dir__)
  DEFAULT_TIMEOUT = 25

  def test_systemd_stop_outlasts_the_swarm_drain
    timeout_stop = Integer(unit.fetch('TimeoutStopSec'))

    assert_operator timeout_stop, :>, DEFAULT_TIMEOUT + Wurk::Swarm::SHUTDOWN_GRACE
    assert_equal 'SIGTERM', unit.fetch('KillSignal')
  end

  def test_systemd_gives_up_on_a_release_that_cannot_boot
    assert_operator Integer(unit.fetch('StartLimitBurst')), :>=, 1
    assert_operator Integer(unit.fetch('StartLimitIntervalSec')), :>,
                    Integer(unit.fetch('StartLimitBurst')) * Integer(unit.fetch('RestartSec'))
    assert_equal 'on-failure', unit.fetch('Restart')
  end

  def test_capistrano_tasks_compile_and_hook_the_deploy
    source = File.read(File.join(ROOT, 'capistrano/wurk.rake'))

    assert RubyVM::InstructionSequence.compile(source)
    %w[quiet restart stop start].each { |task| assert_match(/task :#{task}\b/, source) }
    assert_match(/after 'deploy:starting', 'wurk:quiet'/, source)
    assert_match(/after 'deploy:published', 'wurk:restart'/, source)
  end

  private

  def unit
    File.readlines(File.join(ROOT, 'wurk.service'), chomp: true)
        .grep(/\A[A-Za-z]+=/)
        .to_h { |line| line.split('=', 2) }
  end
end
