# frozen_string_literal: true

require_relative '../test_helper'

class FetchManyQueuesJob
  include Wurk::Job

  RAN = Queue.new

  def perform(tag)
    RAN << tag
  end
end

# R8 (09-production-readiness): a capsule serving 100 queues used to walk them
# one LMOVE round trip at a time. A job pushed through the real Client onto the
# 100th queue must be fetched, run and ACKed by one Processor#process_one —
# one fetch cycle, no BLMOVE block in between. Real Redis, real Processor.
class FetchManyQueuesTest < Wurk::Test::UnitCase
  parallelize_me!

  QUEUE_COUNT = 100

  def setup
    super
    @names = Array.new(QUEUE_COUNT) { |i| "fmq-#{Process.pid}-#{object_id}-#{i}" }
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: Wurk::Test.redis_url }
    @config.queues = @names
    @capsule = @config.default_capsule
    @capsule.prepare!
    @client = Wurk::Client.new(pool: @capsule.redis_pool)
    @processor = Wurk::Processor.new(@capsule)
    FetchManyQueuesJob::RAN.clear
  end

  def test_a_job_on_the_hundredth_queue_runs_within_one_fetch_cycle
    assert_equal :strict, @capsule.mode

    @client.push('class' => FetchManyQueuesJob, 'args' => ['q100'], 'queue' => @names.last)

    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    @processor.process_one
    elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started

    assert_equal 'q100', FetchManyQueuesJob::RAN.pop(timeout: 0)
    assert_operator elapsed, :<, Wurk::Fetcher::Reliable::TIMEOUT / 2.0,
                    'the job must come from the non-blocking pass, not after a BLMOVE block'
    @capsule.fetcher.flush_pending_acks
    @capsule.redis do |conn|
      assert_equal 0, conn.call('LLEN', "queue:#{@names.last}")
      assert_equal 0, conn.call('LLEN', Wurk::Fetcher::Reliable.private_queue_name("queue:#{@names.last}"))
    end
  end
end
