# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'active_support/core_ext/integer/time'
require 'active_support/core_ext/numeric/time'

# Second-valued job options declared as ActiveSupport::Duration, pushed for
# real and read back off the queue. JSON.generate writes a raw Duration as a
# string ("172800"), so each option has to be a plain number before the push
# or the reader after it cannot use it.
class JobOptionDurationTest < Wurk::Test::UnitCase
  class RetryForJob
    include Sidekiq::Job

    sidekiq_options retry_for: 48.hours

    def perform; end
  end

  class BoundsJob
    include Sidekiq::Job

    sidekiq_options timeout: 5.seconds, deadline: 1.minute

    def perform; end
  end

  def setup
    super
    @queue = "jod-#{Process.pid}-#{object_id}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
  end

  def teardown
    Wurk.redis do |c|
      c.call('DEL', "queue:#{@queue}")
      c.call('ZREM', Wurk::Keys::RETRY, *@retried) if @retried&.any?
    end
  ensure
    super
  end

  # Sidekiq 8.1 normalize_item: `item["retry_for"] = item["retry_for"].to_i`.
  def test_class_level_retry_for_duration_is_written_as_integer_seconds
    RetryForJob.set(queue: @queue).perform_async

    assert_equal 172_800, queued['retry_for']
    assert_kind_of Integer, queued['retry_for']
  end

  def test_per_call_retry_for_duration_is_accepted
    RetryForJob.set(queue: @queue, retry_for: 2.hours).perform_async

    assert_equal 7200, queued['retry_for']
  end

  # The budget is what decides: past the default 25 attempts the job still
  # retries, because 48h have not elapsed since failed_at.
  def test_retry_for_duration_overrides_the_attempt_count
    RetryForJob.set(queue: @queue).perform_async
    payload = queued.merge('retry_count' => 30, 'failed_at' => now_ms - 60_000)

    assert_raises(Wurk::JobRetry::Handled) do
      Wurk::JobRetry.new(@config).global(Wurk.dump_json(payload), @queue) { raise 'boom' }
    end
    @retried = Wurk.redis { |c| c.call('ZRANGE', Wurk::Keys::RETRY, 0, -1) }.select { |r| r.include?(payload['jid']) }

    refute_empty @retried, 'retry_for: 48.hours must keep retrying past 25 attempts'
  end

  def test_timeout_and_deadline_durations_are_written_as_numbers
    BoundsJob.set(queue: @queue).perform_async

    assert_equal 5, queued['timeout']
    assert_equal 60, queued['deadline']
    assert Wurk::JobUtil.positive_seconds?(queued['timeout']), 'Middleware::Timeout must be able to arm the bound'
  end

  def test_fractional_timeout_duration_keeps_its_fraction
    BoundsJob.set(queue: @queue, timeout: 1.5.seconds).perform_async

    assert_in_delta 1.5, queued['timeout']
  end

  def test_plain_numeric_bounds_are_untouched
    BoundsJob.set(queue: @queue, timeout: 7, deadline: 2.5).perform_async

    assert_equal 7, queued['timeout']
    assert_kind_of Integer, queued['timeout']
    assert_in_delta 2.5, queued['deadline']
  end

  private

  def queued
    entries = Wurk.redis { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }

    assert_equal 1, entries.size
    JSON.parse(entries.first)
  end

  def now_ms = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
end
