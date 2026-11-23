# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# What a job owes Redis after `perform` returned and its bookkeeping failed.
# Real Redis throughout; the outage is a pool that refuses on demand.
class FinishedJobCleanupTest < Wurk::Test::UnitCase
  parallelize_me!

  class FlakyPool
    attr_writer :down

    def initialize(real)
      @real = real
      @down = true
    end

    def with(...)
      raise RedisClient::CannotConnectError, 'down' if @down

      @real.with(...)
    end
  end

  # Records what the gem's unlock would have been called with.
  class FakeLocksmith
    class << self
      attr_accessor :calls, :failing
    end

    def initialize(item) = @item = item

    def unlock
      raise RedisClient::CannotConnectError, 'down' if self.class.failing

      self.class.calls << @item['lock_digest']
    end
  end

  def setup
    super
    @config = Wurk::Configuration.new
    @log = StringIO.new
    @config.logger = ::Logger.new(@log)
    @errors = []
    @config.error_handlers.replace([->(ex, ctx, _cfg) { @errors << [ex, ctx] }])
    @pool = @config.default_capsule.redis_pool
    @flaky = FlakyPool.new(@pool)
    Wurk::FinishedJobCleanup.reset!
    FakeLocksmith.calls = []
    FakeLocksmith.failing = false
    @locksmith_class = Wurk::UniqueJobsCompat.method(:locksmith_class)
    use_locksmith(FakeLocksmith)
  end

  def teardown
    Wurk::FinishedJobCleanup.reset!
    Wurk::UniqueJobsCompat.define_singleton_method(:locksmith_class, @locksmith_class)
    @config.reset_redis_pools!
  ensure
    super
  end

  def test_a_job_owing_nothing_is_only_reported
    settle({ 'class' => 'J', 'jid' => 'j1' })

    assert_equal 0, Wurk::FinishedJobCleanup.pending
    assert_equal 1, @errors.size
  end

  def test_a_lock_is_released_on_the_spot_when_redis_is_back
    settle(locked_job('uniquejobs:abc'))

    assert_equal %w[uniquejobs:abc uniquejobs:abc:RUN], FakeLocksmith.calls
    assert_equal 0, Wurk::FinishedJobCleanup.pending
  end

  def test_a_run_digest_releases_its_base_lock_too
    settle(locked_job('uniquejobs:abc:RUN'))

    assert_equal %w[uniquejobs:abc uniquejobs:abc:RUN], FakeLocksmith.calls
  end

  def test_a_lock_meant_to_outlive_the_job_is_left_alone
    settle(locked_job('uniquejobs:abc').merge('lock' => 'until_expired'))

    assert_empty FakeLocksmith.calls
  end

  def test_a_lock_waits_for_redis_and_is_released_when_it_returns
    FakeLocksmith.failing = true
    settle(locked_job('uniquejobs:abc'))

    assert_equal 1, Wurk::FinishedJobCleanup.pending
    assert_includes @log.string, 'waiting for Redis'
    assert_includes @errors.first.first.message, 'uniquejobs:abc'

    drain_now

    assert_equal 1, Wurk::FinishedJobCleanup.pending
    FakeLocksmith.failing = false
    drain_now

    assert_equal 0, Wurk::FinishedJobCleanup.pending
    assert_equal %w[uniquejobs:abc uniquejobs:abc:RUN], FakeLocksmith.calls
  end

  def test_a_failed_drain_backs_off
    FakeLocksmith.failing = true
    settle(locked_job('uniquejobs:abc'))
    drain_now
    FakeLocksmith.failing = false

    Wurk::FinishedJobCleanup.drain

    assert_equal 1, Wurk::FinishedJobCleanup.pending, 'no second try inside the backoff'
  end

  def test_a_stopping_process_names_the_lock_it_left
    FakeLocksmith.failing = true
    settle(locked_job('uniquejobs:abc'))

    Wurk::FinishedJobCleanup.give_up

    assert_equal 0, Wurk::FinishedJobCleanup.pending
    assert_includes @log.string, 'Locks left: uniquejobs:abc, uniquejobs:abc:RUN'
  end

  def test_an_error_that_is_not_redis_is_reported_and_not_retried
    locksmith = Class.new(FakeLocksmith) { def unlock = raise(ArgumentError, 'bad') }
    with_locksmith(locksmith) { settle(locked_job('uniquejobs:abc')) }

    assert_equal 0, Wurk::FinishedJobCleanup.pending
    assert_instance_of ArgumentError, @errors.last.first
  end

  def test_the_memory_is_bounded_and_says_what_it_dropped
    FakeLocksmith.failing = true
    original = Wurk::FinishedJobCleanup::MEMORY
    silence_constant(:MEMORY, 1)
    settle(locked_job('uniquejobs:first'))
    settle(locked_job('uniquejobs:second'))

    assert_equal 1, Wurk::FinishedJobCleanup.pending
    assert_includes @log.string, 'Locks left: uniquejobs:first'
  ensure
    silence_constant(:MEMORY, original)
  end

  # The batch hears the job succeeded once Redis answers: nothing runs again.
  def test_a_batch_ack_waits_for_redis_and_completes_the_batch
    bid = SecureRandom.hex(8)
    jid = SecureRandom.hex(12)
    seed_batch(bid, jid)

    settle({ 'class' => 'J', 'jid' => jid, 'bid' => bid }, pool: @flaky)

    assert_equal 1, Wurk::FinishedJobCleanup.pending
    assert_equal '1', hget("b-#{bid}", 'pending')
    @flaky.down = false
    drain_now

    assert_equal 0, Wurk::FinishedJobCleanup.pending
    assert_equal '0', hget("b-#{bid}", 'pending')
  ensure
    @pool.with { |c| c.call('DEL', "b-#{bid}", "b-#{bid}-jids", "b-#{bid}-failed", "b-#{bid}-pkids") }
  end

  private

  def settle(job, pool: @pool)
    error = RedisClient::CannotConnectError.new('down')
    Wurk::FinishedJobCleanup.settle(job, error, pool: pool, config: @config)
  end

  def locked_job(digest)
    { 'class' => 'J', 'jid' => SecureRandom.hex(6), 'lock' => 'until_executed', 'lock_digest' => digest }
  end

  def drain_now
    Wurk::FinishedJobCleanup.instance_variable_set(:@next_try, 0.0)
    Wurk::FinishedJobCleanup.drain
  end

  # The live copy's Locksmith, gem or native, is what the cleanup unlocks with.
  def use_locksmith(klass)
    Wurk::UniqueJobsCompat.define_singleton_method(:locksmith_class) { klass }
  end

  def with_locksmith(klass)
    use_locksmith(klass)
    yield
  ensure
    use_locksmith(FakeLocksmith)
  end

  def silence_constant(name, value)
    Wurk::FinishedJobCleanup.send(:remove_const, name)
    Wurk::FinishedJobCleanup.const_set(name, value)
  end

  def seed_batch(bid, jid)
    @pool.with do |c|
      c.call('HSET', "b-#{bid}", 'pending', 1, 'total', 1, 'kids', 0)
      c.call('SADD', "b-#{bid}-jids", jid)
    end
  end

  def hget(key, field) = @pool.with { |c| c.call('HGET', key, field) }
end
