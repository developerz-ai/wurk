# frozen_string_literal: true

require_relative '../test_helper'

# `fake!` and `inline!` replace the Redis write, so a suite with no Redis at all
# (a CI runner without one) must enqueue at memory speed. The pool here points at
# a port nothing listens on, and the pool retries a refused connect with backoff
# for seconds before giving up (RedisPool::CONN_MAX_ATTEMPTS): a push that dialed
# even once would blow the bound by an order of magnitude.
class TestingNoRedisTest < Wurk::Test::UnitCase
  parallelize_me!

  BOUND = 0.1

  class NoopJob
    include Sidekiq::Job

    def perform(*); end
  end

  def setup
    super
    @pool = Wurk::RedisPool.new(size: 1, url: 'redis://127.0.0.1:1/3')
  end

  def teardown
    Sidekiq::Queues.clear_all
  ensure
    super
  end

  def test_fake_mode_enqueues_without_dialing_redis
    elapsed = timed do
      Sidekiq::Testing.fake! { enqueue_every_way }
    end

    assert_operator elapsed, :<, BOUND, "fake push took #{elapsed.round(3)}s: it opened a socket"
    assert_equal 4, NoopJob.jobs.size
  end

  def test_inline_mode_runs_without_dialing_redis
    elapsed = timed do
      Sidekiq::Testing.inline! { enqueue_every_way }
    end

    assert_operator elapsed, :<, BOUND, "inline push took #{elapsed.round(3)}s: it opened a socket"
  end

  # The control: the same pool does dial outside a mode. Asked of the pool
  # itself, not through a push: a push's outcome also depends on the client's
  # configured reliability (an earlier test in the worker may leave
  # reliable_push on, which buffers the failed push instead of raising).
  def test_the_pool_would_have_dialed_outside_a_test_mode
    assert_raises(RedisClient::CannotConnectError) { @pool.with { |conn| conn.call('PING') } }
  end

  private

  def enqueue_every_way
    Sidekiq::Client.via(@pool) do
      NoopJob.perform_async(1)
      NoopJob.perform_in(60, 2)
      NoopJob.perform_bulk([[3], [4]])
    end
  end

  def timed
    started = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    yield
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started
  end
end
