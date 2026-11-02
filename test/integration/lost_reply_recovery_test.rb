# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/reply_dropping_proxy'

class LostReplyRecoveryJob
  include Wurk::Job

  RAN = Queue.new

  def perform(tag)
    RAN << tag
  end
end

class LostReplyFailingJob
  include Wurk::Job

  RAN = Queue.new

  def perform(tag)
    RAN << tag
    raise 'fails while Redis refuses the retry'
  end
end

# A claim the server applied and whose reply was lost: the client re-sends, so
# the first job sits in the live owner's private list with no thread holding it.
# Nothing else recovers it while the owner lives. Real Redis behind a real TCP
# relay that drops the reply.
class LostReplyRecoveryTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @queue_name = "lost-reply-#{Process.pid}-#{object_id}"
    @public_queue = Wurk::Keys.queue(@queue_name)
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @proxy = Wurk::Test::ReplyDroppingProxy.new(Wurk::Test.redis_url)
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: @proxy.url }
    @capsule = @config.default_capsule
    @capsule.queues = [@queue_name]
    @capsule.concurrency = 1
    @capsule.prepare!
    @private_list = Wurk::Fetcher::Reliable.private_queue_name(@public_queue)
  end

  def teardown
    @reaper&.stop
    @manager&.stop(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1)
    @proxy.stop!
    @observer.call('DEL', @public_queue, @private_list)
    @observer.close
    @config.reset_redis_pools!
  ensure
    super
  end

  def test_a_job_whose_claim_reply_was_lost_runs_exactly_once
    push(LostReplyRecoveryJob, 'first')
    push(LostReplyRecoveryJob, 'second')
    @proxy.drop_reply_to(/LMOVE/)

    start_worker

    ran = [LostReplyRecoveryJob::RAN.pop(timeout: 15), LostReplyRecoveryJob::RAN.pop(timeout: 15)]

    assert_equal 1, @proxy.dropped
    assert_equal %w[first second], ran.sort
    assert_nil LostReplyRecoveryJob::RAN.pop(timeout: 0.5), 'nothing ran twice'
    wait_until { @observer.call('LLEN', @private_list).zero? }
  end

  # An unconditional RPUSH + LREM: a re-send after a lost reply finds nothing to
  # LREM and pushes the job a second time.
  def test_requeue_does_not_double_push_on_a_lost_reply
    payload = Wurk.dump_json('class' => 'X', 'args' => [], 'jid' => SecureRandom.hex(12), 'queue' => @queue_name)
    @observer.call('LPUSH', @private_list, payload)
    uow = Wurk::Fetcher::Reliable::UnitOfWork.new(queue: @public_queue, queue_name: @queue_name,
                                                  private_queue: @private_list, job: payload, config: @capsule)
    @capsule.redis { |c| Wurk::Lua::Loader.script_load_all(c) }
    @proxy.drop_reply_to(/EVALSHA/)

    assert_raises(RedisClient::ConnectionError) { uow.requeue }

    assert_equal 1, @observer.call('LLEN', @public_queue), 'exactly one copy back on the queue'
    assert_equal 0, @observer.call('LLEN', @private_list)
  end

  private

  def push(klass, tag)
    @observer.call('LPUSH', @public_queue,
                   Wurk.dump_json('class' => klass.name, 'args' => [tag], 'jid' => SecureRandom.hex(12),
                                  'queue' => @queue_name, 'retry' => false))
  end

  def start_worker
    @manager = Wurk::Manager.new(@capsule)
    @manager.start
    @reaper = Wurk::Fetcher::Reaper.new(@config, interval: 0.1, reconcile_confirm: 0.2,
                                                 lock_key: "lock-#{@queue_name}")
    @reaper.start
  end

  def wait_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    assert yield, 'condition never held'
  end
end
