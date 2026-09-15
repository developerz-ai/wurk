# frozen_string_literal: true

require_relative '../engine_test_helper'

require 'securerandom'

# End-to-end proof that an ActiveJob enqueued through the dummy app's
# `:wurk` queue_adapter actually runs the body, not just lands in Redis.
# The dummy at test/dummy/config/application.rb:29 sets
#   config.active_job.queue_adapter = :wurk
# so `SimpleJob.perform_later(token)` is pushed via Wurk::Client#raw_push,
# and under `Wurk::Testing.inline!` the push hook in lib/wurk/testing.rb:105
# synchronously calls `SimpleJob.process_job(payload)` — which invokes
# `perform(token)`. The body writes the sentinel key
# `simple_job:<token> = Process.pid` (with a 60s EX) at the integration
# boundary; this test is the only reader, so the key's mere existence and
# value close the round-trip.
#
# Parallel safety: `SecureRandom.hex(4)` makes the token unique across
# forks and reruns, and the per-worker FLUSHDB in test_helper.rb:21-27
# clears any stale sentinel left from a previous worker before this one
# starts, so no explicit DEL is needed in teardown.
class ActiveJobRoundtripEngineTest < Wurk::Test::EngineCase
  parallelize_me!

  def test_perform_later_runs_the_body_under_the_wurk_adapter
    assert_equal :wurk, ActiveJob::Base.queue_adapter_name,
                 'precondition: dummy app must use the Wurk ActiveJob adapter'

    token = "t-#{SecureRandom.hex(4)}"
    key   = "simple_job:#{token}"

    Wurk::Testing.inline! do
      SimpleJob.perform_later(token)
    end

    stored = Wurk.redis { |c| c.call('GET', key) }

    refute_nil stored, "expected #{key} to exist after perform_later under :inline"
    assert_equal Process.pid.to_s, stored,
                 "#{key} must hold the PID of the process that ran perform"
  end
end