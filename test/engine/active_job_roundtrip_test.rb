# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'securerandom'

# End-to-end ActiveJob roundtrip through the dummy app's `:wurk` adapter.
# Exercises the path most apps use day-to-day: `MyJob.perform_later(arg)` must
# actually invoke `MyJob#perform(arg)` with the same argument the caller
# passed, on the same process the test is running in (so a future change to
# the inline-mode plumbing — `Wurk::Testing.inline_push`, the WurkAdapter's
# enqueue, or the worker-setter's `process_job` — can't silently break it).
# The sentinel is the simplest possible contract: a SET to
# `simple_job:<args.first>` carrying `::Process.pid` (issue #486).
#
# Parallel safety: the dummy's queue_adapter is `:wurk`, but `WURK_DISABLED=1`
# is set in engine_test_helper so the railtie never forks a swarm; inline
# mode runs synchronously in this process. Per-test args (random hex) plus
# per-worker Redis DB isolation + the `RedisNamespace` teardown flush keep
# concurrent classes from seeing each other's keys.
class ActiveJobRoundtripTest < Wurk::Test::EngineCase
  parallelize_me!

  def test_perform_later_invokes_perform_with_the_passed_args
    token = "t-#{::SecureRandom.hex(4)}"
    key = "simple_job:#{token}"

    refute ::Wurk.redis { |c| c.call('EXISTS', key).positive? },
           "test fixture leaked a sentinel at #{key.inspect}"

    ::Wurk::Testing.inline! { ::SimpleJob.perform_later(token) }

    stored = ::Wurk.redis { |c| c.call('GET', key) }

    refute_nil stored, "expected the sentinel #{key.inspect} to be set by SimpleJob#perform"
    assert_equal ::Process.pid.to_s, stored
  end
end