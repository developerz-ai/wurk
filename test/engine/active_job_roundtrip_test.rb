# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'securerandom'

# End-to-end ActiveJob round-trip inside the booted dummy Rails app:
# `SimpleJob.perform_later(token)` → Wurk adapter → enqueue → `Wurk::Testing.inline!`
# pulls it back → Sidekiq::ActiveJob::Wrapper → user's `SimpleJob#perform` writes
# a sentinel into Redis → the test reads that sentinel back through `Wurk.redis`.
# If any link in that chain is broken (adapter not installed, wrapper not
# resolved, testing mode bypassed, Rails autoloader cache stale) the key never
# appears and the assertion fails.
#
# Parallel safety: `Wurk::Testing.inline!` is process-global, and parallel
# workers share this process class — but every worker is on its own Redis DB
# (test_helper's after_parallel_fork) and the key is scoped to a per-call
# `SecureRandom.hex(4)` token, so concurrent runs cannot collide. test_helper's
# teardown FLUSHDB clears the sentinel after the run.
class ActiveJobRoundtripEngineTest < Wurk::Test::EngineCase
  parallelize_me!

  def test_perform_later_runs_inline_and_writes_sentinel
    token = "t-#{SecureRandom.hex(4)}"
    key = "simple_job:#{token}"

    Wurk::Testing.inline! do
      SimpleJob.perform_later(token)
    end

    value = Wurk.redis { |c| c.call('GET', key) }

    refute_nil value, "expected sentinel at #{key} after inline perform"
    assert_equal Process.pid.to_s, value
  end
end