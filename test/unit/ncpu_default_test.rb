# frozen_string_literal: true

require_relative '../test_helper'
require 'etc'

# The parallel worker DEFAULT must never put a worker on every core. This
# suite's integration layer waits on real timeouts — a swarm of children, BLMOVE
# blocks, 1s pool read timeouts — so an oversubscribed machine fails on wall
# clock rather than on assertions, which reads as a flaky suite instead of a
# loaded one (dz#4386: a flat default of 4 on 4-core fleet boxes).
#
# Properties, never the formula: restating `[[nprocessors / 2, 1].max, 4].min`
# here would pass for any arithmetic the constant happens to contain.
class NcpuDefaultTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_never_forks_more_workers_than_the_machine_has_cores
    assert_operator Wurk::Test::DEFAULT_NCPU, :<=, Etc.nprocessors
    assert_operator Wurk::Test::DEFAULT_NCPU, :<=, 4
  end

  def test_always_forks_at_least_one_worker_and_never_shares_a_redis_db
    assert_operator Wurk::Test::DEFAULT_NCPU, :>=, 1
    assert_operator Wurk::Test::DEFAULT_NCPU, :<=, Wurk::Test::WORKER_DATABASES
  end
end
