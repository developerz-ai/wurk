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
    Object.send(:remove_const, @aj_const_name) if @aj_const_name && Object.const_defined?(@aj_const_name)
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

  # AJ server `options:` regression: an ActiveJob class with
  # `sidekiq_options queue: 'priority', retry: 3` must see those values
  # in the executed payload. The queue flows from the AJ's `queue_name`
  # (which `queue_as` sets — the WurkAdapter passes `job.queue_name` to
  # the wrapper's `set(queue: ...)`); the retry flows from the wrapped
  # class's `sidekiq_options` via `JobUtil#defaults_for`'s merge chain
  # (`class_defaults` → `wrapped.get_sidekiq_options` → `item`).
  #
  # The wrapper's `perform(job_data)` runs through
  # `capsule.server_middleware` (Processor#execute_job) with the
  # resolved payload, then `ActiveJob::Base.execute(job_data)` rebuilds
  # the AJ instance — `queue_name` is set on the instance from the
  # payload, and the class's `get_sidekiq_options['retry']` is what
  # `JobRetry#local` reads when the job fails.
  def test_sidekiq_options_survive_the_perform_path
    options_key = "aj_options_job:#{@arg}"
    klass = Class.new(::ActiveJob::Base) do
      def perform(arg)
        # self.queue_name is set by AJ from the wrapper's job_data['queue'];
        # the wrapped class's sidekiq_options flowed into the payload via
        # JobUtil#defaults_for.
        ::Wurk.redis do |c|
          c.call('HSET', "aj_options_job:#{arg}",
                 'queue', queue_name,
                 'retry', self.class.get_sidekiq_options['retry'])
        end
      end
    end
    klass.queue_as :priority
    klass.queue_adapter = :wurk
    klass.sidekiq_options 'retry' => 3
    name = "AJOptsEngineJob_#{::Process.pid}_#{object_id}_#{rand(1 << 32)}"
    Object.const_set(name, klass)
    @aj_const_name = name

    ::Wurk::Testing.inline! { klass.perform_later(@arg) }

    queue, retry_val = ::Wurk.redis { |c| c.call('HMGET', options_key, 'queue', 'retry') }

    assert_equal 'priority', queue, 'queue_as :priority must flow into the executed payload'
    assert_equal '3', retry_val, 'sidekiq_options retry: 3 must flow into the executed payload'
  ensure
    ::Wurk.redis { |c| c.call('DEL', options_key) } if defined?(options_key)
  end
end
