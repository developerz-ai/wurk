# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'securerandom'

# End-to-end proof that an ActiveJob enqueued through Wurk's adapter inside
# the booted dummy app actually executes and reaches the side effect its
# perform method describes. With `WURK_DISABLED=1` (engine_test_helper)
# `Wurk::RailsBoot` will NOT fork a worker to drain the queue, so the only
# way the sentinel key appears in the test-worker's Redis DB is
# `Wurk::Testing.inline!` executing the job synchronously in this thread.
#
# Parallel safety: the arg is `t-` + SecureRandom.hex(4), so the
# `simple_job:<arg>` key is unique across concurrent workers. Redis DB
# isolation (1..14 per worker) and teardown FLUSHDB are inherited from
# test_helper.rb.
class ActiveJobRoundtripEngineTest < Wurk::Test::EngineCase
  parallelize_me!

  def test_perform_later_writes_sentinel_to_redis
    arg = "t-#{SecureRandom.hex(4)}"
    key = "simple_job:#{arg}"

    Wurk::Testing.inline! do
      SimpleJob.perform_later(arg)
    end

    value = Wurk.redis { |c| c.call('GET', key) }

    refute_nil value, "expected SimpleJob to write #{key} during inline execution"
    assert_equal Process.pid.to_s, value
  end
end