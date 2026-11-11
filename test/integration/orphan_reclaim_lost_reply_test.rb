# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/reply_dropping_proxy'
require 'securerandom'

# #908: the reclaim script moves a poison job from its private list to the dead
# set and the death handlers run once it returns. A reply lost in between left
# the job dead with no handler ever told: the private-list entry was gone, so no
# later sweep could find it again. Real Redis behind a relay that applies the
# script and drops its reply.
class OrphanReclaimLostReplyTest < Wurk::Test::UnitCase
  parallelize_me!

  DEAD_PID = 999_999
  THRESHOLD = Wurk::Middleware::PoisonPill::RECOVERY_THRESHOLD

  def setup
    super
    @queue_name = "lost-reclaim-#{Process.pid}-#{object_id}"
    @public_queue = Wurk::Keys.queue(@queue_name)
    @private_list = "#{@public_queue}|#{Wurk::Component.hostname}|#{DEAD_PID}|#{Wurk::Component::PROCESS_NONCE}|0"
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
    Wurk::Lua::Loader.load_missing(@observer)
    @proxy = Wurk::Test::ReplyDroppingProxy.new(Wurk::Test.redis_url)
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: @proxy.url }
    @deaths = []
    @death_handler = ->(job, ex) { @deaths << [job['jid'], ex.class] }
    Wurk.configuration.death_handlers << @death_handler
  end

  def teardown
    Wurk.configuration.death_handlers.delete(@death_handler)
    @proxy.stop!
    @observer.close
    @config.reset_redis_pools!
  ensure
    super
  end

  def test_a_kill_whose_reply_was_lost_still_fires_the_death_handlers
    jid = SecureRandom.hex(12)
    payload = orphan(jid, prior_recoveries: THRESHOLD)
    @proxy.drop_reply_to(/#{jid}/)

    assert reclaim(payload), 'the kill this call made is reported as a move'

    assert_equal 1, @proxy.dropped
    assert_equal [[jid, Wurk::Middleware::PoisonPill::Poisoned]], @deaths, 'death handlers fire once'
    assert_equal [payload], @observer.call('ZRANGE', Wurk::Keys::DEAD, 0, -1)
    assert_equal 0, @observer.call('LLEN', @private_list)
    assert_equal 0, @observer.call('LLEN', @public_queue)
  end

  def test_a_requeue_whose_reply_was_lost_kills_nothing
    jid = SecureRandom.hex(12)
    payload = orphan(jid, prior_recoveries: 0)
    @proxy.drop_reply_to(/#{jid}/)

    refute reclaim(payload), 'a requeue cannot be told from another reaper moving it'

    assert_equal 1, @proxy.dropped
    assert_empty @deaths
    assert_equal [payload], @observer.call('LRANGE', @public_queue, 0, -1)
    assert_equal 0, @observer.call('ZCARD', Wurk::Keys::DEAD)
  end

  private

  def reclaim(payload)
    Wurk::Fetcher::OrphanReclaim.new(@config).call(@private_list, @public_queue, payload)
  end

  def orphan(jid, prior_recoveries:)
    payload = Wurk.dump_json('class' => 'LostReclaimJob', 'args' => [], 'queue' => @queue_name, 'jid' => jid)
    @observer.call('SET', Wurk::Middleware::PoisonPill.counter_key(jid), prior_recoveries) if prior_recoveries.positive?
    @observer.call('RPUSH', @private_list, payload)
    payload
  end
end
