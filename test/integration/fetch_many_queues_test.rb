# frozen_string_literal: true

require_relative '../test_helper'

class FetchManyQueuesJob
  include Wurk::Job

  # The tag each run records. A Mutex+ConditionVariable pair, not a
  # Thread::Queue: the take below is the repo's own wait idiom
  # (lib/wurk/client/buffered.rb), the same one the reaper's sweep uses.
  class Mailbox
    def initialize
      @lock = ::Mutex.new
      @wake = ::ConditionVariable.new
      @tags = []
    end

    def <<(tag)
      @lock.synchronize do
        @tags << tag
        @wake.broadcast
      end
    end

    # The oldest tag, or nil when none arrives within `timeout` seconds.
    def take(timeout: 0)
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + timeout
      @lock.synchronize do
        while @tags.empty?
          remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          @wake.wait(@lock, remaining)
        end
        @tags.shift
      end
    end

    def clear
      @lock.synchronize { @tags.clear }
    end
  end

  RAN = Mailbox.new

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

  # CI run 41303800609, job "compat (ruby 3.2.11, rails 8.1, redis)", failed
  # this case on the Ruby 3.2 floor at the assertion that reads the tag back.
  # That read was a timed `Thread::Queue#pop(timeout:)` — the one timed wait in
  # `lib/` that does not use the repo's Mutex+ConditionVariable idiom
  # (lib/wurk/client/buffered.rb, lib/wurk/timer_loop.rb). The reaper's sweep
  # waits the same way, inside its raw thread, so a wait that raised there took
  # the sweep thread down with it (the thread exceptions in that log). The
  # mailbox above is that idiom now: the assertion, its bound and the
  # one-fetch-cycle meaning are unchanged.
  # The script sends two keys per queue per thread per poll. A pass that found
  # nothing answers for the whole fetcher for a moment, so an idle capsule's
  # threads do not each pay for the same empty answer.
  def test_an_empty_script_pass_answers_for_the_fetcher
    @config.fetch_poll_interval = 0.01
    fetcher = @capsule.fetcher
    scripts = 0
    original = Wurk::Lua::Loader.method(:eval_cached)
    Wurk::Lua::Loader.define_singleton_method(:eval_cached) do |conn, name, **kw|
      scripts += 1 if name == :fetch_first
      original.call(conn, name, **kw)
    end

    5.times { fetcher.retrieve_work }

    assert_operator scripts, :<, 5, 'most passes skip the script inside the window'
  ensure
    Wurk::Lua::Loader.define_singleton_method(:eval_cached, original)
  end

  def test_a_job_landing_after_the_window_is_found_by_the_script
    @config.fetch_poll_interval = 0.01
    fetcher = @capsule.fetcher
    fetcher.retrieve_work
    @client.push('class' => FetchManyQueuesJob, 'args' => ['late'], 'queue' => @names.last)

    assert_nil fetcher.retrieve_work, 'inside the window the script is skipped'
    sleep Wurk::Fetcher::ManyQueues::REST_MISS_BACKOFF + 0.02
    uow = fetcher.retrieve_work

    assert_includes uow.job, 'late'
    uow.acknowledge
    uow.release_claim
    fetcher.flush_pending_acks
  end

  def test_a_script_pass_that_found_a_job_does_not_hold_the_others_off
    @config.fetch_poll_interval = 0.01
    fetcher = @capsule.fetcher
    2.times { |i| @client.push('class' => FetchManyQueuesJob, 'args' => [i], 'queue' => @names.last) }

    2.times do
      uow = fetcher.retrieve_work

      refute_nil uow
      uow.acknowledge
      uow.release_claim
    end
    fetcher.flush_pending_acks
  end

  def test_a_job_on_the_hundredth_queue_runs_within_one_fetch_cycle
    assert_equal :strict, @capsule.mode

    @client.push('class' => FetchManyQueuesJob, 'args' => ['q100'], 'queue' => @names.last)

    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    @processor.process_one
    elapsed = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started

    assert_equal 'q100', FetchManyQueuesJob::RAN.take(timeout: 0)
    assert_operator elapsed, :<, Wurk::Fetcher::Reliable::TIMEOUT / 2.0,
                    'the job must come from the non-blocking pass, not after a BLMOVE block'
    @capsule.fetcher.flush_pending_acks
    @capsule.redis do |conn|
      assert_equal 0, conn.call('LLEN', "queue:#{@names.last}")
      assert_equal 0, conn.call('LLEN', Wurk::Fetcher::Reliable.private_queue_name("queue:#{@names.last}"))
    end
  end
end
