# frozen_string_literal: true

require_relative '../test_helper'

class QueueConsumersTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @out = StringIO.new
    @config = Wurk::Configuration.new
    @config.redis = { url: Wurk::Test.redis_url }
    @config.logger = ::Logger.new(@out)
    @redis = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @now = 0
    @watch = Wurk::QueueConsumers::Watch.new(@config, grace: 300, throttle: 3600, clock: -> { @now })
  end

  def teardown
    @redis&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_counts_every_live_subscriber_across_capsules_and_skips_expired_identities
    live('a:1:n', %w[default mail])
    live('a:2:n', %w[default])
    @redis.call('SADD', Wurk::Keys::PROCESSES, 'gone:1:n')

    counts = @config.redis { |c| Wurk::QueueConsumers.counts(c) }

    assert_equal({ 'default' => 2, 'mail' => 1 }, counts)
  end

  def test_tolerates_unparseable_info
    assert_empty Wurk::QueueConsumers.subscribed('{nope')
    assert_empty Wurk::QueueConsumers.subscribed(nil)
  end

  def test_warns_only_after_the_grace_period_so_a_rolling_restart_stays_quiet
    live('a:1:n', %w[default])
    job('ghost')

    assert_empty @watch.check
    @now = 299

    assert_empty @watch.check
    @now = 300

    assert_equal %w[ghost], @watch.check
    assert_match(/"ghost" has 1 jobs/, @out.string)
  end

  def test_a_queue_that_regains_a_consumer_restarts_its_clock
    live('a:1:n', %w[default])
    job('ghost')
    @watch.check
    @now = 200
    live('b:1:n', %w[ghost])
    @watch.check
    @redis.call('DEL', 'b:1:n')
    @redis.call('SREM', Wurk::Keys::PROCESSES, 'b:1:n')
    @now = 400

    assert_empty @watch.check, 'the window since it lost its consumer is only starting'
  end

  def test_warning_is_throttled_per_queue
    live('a:1:n', %w[default])
    job('ghost')
    @watch.check
    @now = 300

    assert_equal %w[ghost], @watch.check
    @now = 3899

    assert_empty @watch.check
    @now = 3900

    assert_equal %w[ghost], @watch.check
  end

  def test_empty_and_subscribed_queues_are_never_reported
    live('a:1:n', %w[default])
    @redis.call('SADD', Wurk::Keys::QUEUES_SET, 'drained')
    job('default')
    @now = 10_000
    @watch.check
    @now = 20_000

    assert_empty @watch.check
  end

  def test_a_fleet_with_no_live_process_is_not_this_warning
    job('ghost')
    @watch.check
    @now = 10_000

    assert_empty @watch.check
  end

  def test_tick_is_gated_on_leadership
    live('a:1:n', %w[default])
    job('ghost')
    @now = 10_000
    @watch.tick

    assert_empty @out.string
  end

  private

  def live(identity, queues)
    @redis.call('SADD', Wurk::Keys::PROCESSES, identity)
    @redis.call('HSET', identity, 'info', ::JSON.generate('queues' => queues))
  end

  def job(queue)
    @redis.call('SADD', Wurk::Keys::QUEUES_SET, queue)
    @redis.call('LPUSH', "queue:#{queue}", '{"class":"X"}')
  end
end
