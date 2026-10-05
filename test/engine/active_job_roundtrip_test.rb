# frozen_string_literal: true

require_relative '../engine_test_helper'

# #486: an ActiveJob enqueued through the dummy app's `:wurk` adapter under
# `Wurk::Testing.inline!` must actually execute — Client#raw_push →
# Testing.inline_push → Wurk::ActiveJob::Wrapper → SimpleJob#perform. The
# sentinel SimpleJob writes is the proof; the sibling adapter test only checks
# the enqueued payload shape and never runs a job.
#
# Transactions: EngineCase runs each test inside a transaction that never
# commits, and the adapter asks for enqueue-after-commit. Verified (Rails 8.1):
# the push still reaches the inline path — Rails 8.1 reads the job class's
# `enqueue_after_transaction_commit` (false here), and even forced to true it
# runs at once, because the only open transaction is the fixture's own. So
# transactional tests stay on; the assertion fails if that ever changes.
#
# Cleanup: EngineCase has no FLUSHDB teardown, so the sentinel is DEL'd
# explicitly rather than left to its 60s TTL.
class ActiveJobRoundtripEngineTest < Wurk::Test::EngineCase
  parallelize_me!

  def setup
    super
    @arg = "t-#{SecureRandom.hex(4)}"
    @key = "simple_job:#{@arg}"
  end

  def teardown
    ::Wurk.redis { |c| c.call('DEL', @key) }
  ensure
    super
  end

  def test_perform_later_runs_the_job_inline_through_the_wurk_adapter
    assert_kind_of ActiveJob::QueueAdapters::WurkAdapter, SimpleJob.queue_adapter

    ::Wurk::Testing.inline! { SimpleJob.perform_later(@arg) }

    value, ttl = ::Wurk.redis { |c| [c.call('GET', @key), c.call('TTL', @key)] }

    assert_equal ::Process.pid.to_s, value
    assert_operator ttl, :>, 0
  end
end
