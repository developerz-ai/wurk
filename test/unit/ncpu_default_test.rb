# frozen_string_literal: true

require_relative '../test_helper'
require 'etc'

# The parallel worker default must never put a worker on every core. This
# suite's integration layer waits on real timeouts, so an oversubscribed machine
# fails on wall clock rather than on assertions, which reads as a flaky suite
# instead of a loaded one (dz#4386: a flat default of 4 on 4-core fleet boxes).
#
# The rule is tested as a FUNCTION OF THE CORE COUNT, because that is the only
# way to state what it does on machines this one is not. Asserting
# `DEFAULT_NCPU == (Etc.nprocessors / 2).clamp(1, 4)` would re-derive the
# expression the constant already holds and pass for any arithmetic inside it.
class NcpuDefaultTest < Wurk::Test::UnitCase
  parallelize_me!

  # One worker per core is the shape this rule exists to avoid, so the table is
  # the assertion: half the cores, never below one, never above the historical
  # four. 4 is the fleet box; 6 is a developer laptop; 64 is a CI monster.
  CASES = { 1 => 1, 2 => 1, 3 => 1, 4 => 2, 6 => 3, 8 => 4, 12 => 4, 64 => 4 }.freeze

  def test_halves_the_cores_between_one_and_the_historical_four
    actual = CASES.keys.to_h { |cores| [cores, Wurk::Test.default_ncpu(cores)] }

    assert_equal CASES, actual
  end

  def test_never_forks_more_workers_than_the_machine_has_cores
    CASES.each_key do |cores|
      assert_operator Wurk::Test.default_ncpu(cores), :<=, cores,
                      "#{cores} cores must not fork more than #{cores} workers"
    end
  end

  # The constant every run actually uses, bound to this machine.
  def test_this_machine_uses_the_rule_and_stays_inside_the_redis_databases
    assert_equal Wurk::Test.default_ncpu(Etc.nprocessors), Wurk::Test::DEFAULT_NCPU
    assert_operator Wurk::Test::DEFAULT_NCPU, :<=, Wurk::Test::WORKER_DATABASES
  end
end
