# frozen_string_literal: true

require_relative '../test_helper'

# A move between two keys has to survive the write half being refused. Dragonfly
# at maxmemory does that part way through a MULTI or a script and applies the
# rest, so an order of remove-then-add loses the job. A key of the wrong type gets
# the same refusal out of every server, which keeps this runnable anywhere: the
# maxmemory form against real Dragonfly is in the docs' verification note.
class FetcherPushBeforeRemoveTest < Wurk::Test::UnitCase
  def setup
    super
    @queue = "pbr-#{SecureRandom.hex(4)}"
    @public_q = "queue:#{@queue}"
    @config = Wurk.configuration
    @payload = Wurk.dump_json('class' => 'X', 'args' => [], 'jid' => SecureRandom.hex(12), 'queue' => @queue)
    @fetcher = Wurk::Fetcher::Reliable.new(@config.default_capsule)
    @private_list = Wurk::Fetcher::Reliable.private_queue_name(@public_q)
    redis('RPUSH', @private_list, @payload)
    redis('SET', @public_q, 'not a list')
  end

  def test_a_refused_push_leaves_the_job_in_the_private_list_on_requeue
    assert_raises(RedisClient::CommandError) { unit.requeue }

    assert_equal [@payload], redis('LRANGE', @private_list, 0, -1)
  end

  def test_a_refused_push_leaves_the_job_in_the_private_list_on_bulk_requeue
    assert_raises(RedisClient::CommandError) { @fetcher.bulk_requeue([unit]) }

    assert_equal [@payload], redis('LRANGE', @private_list, 0, -1)
  end

  def test_a_refused_push_leaves_the_job_in_the_private_list_on_reclaim
    assert_raises(RedisClient::CommandError) { reclaim_one }

    assert_equal [@payload], redis('LRANGE', @private_list, 0, -1)
  end

  def test_requeue_still_pushes_a_job_whose_ack_already_went_out
    redis('DEL', @public_q, @private_list)

    unit.requeue

    assert_equal [@payload], redis('LRANGE', @public_q, 0, -1)
  end

  def test_requeue_without_a_private_list_is_a_bare_push
    redis('DEL', @public_q, @private_list)

    unit(private_queue: nil).requeue

    assert_equal [@payload], redis('LRANGE', @public_q, 0, -1)
  end

  def test_bulk_requeue_does_not_push_a_job_already_acked
    redis('DEL', @public_q, @private_list)

    @fetcher.bulk_requeue([unit])

    assert_equal 0, redis('LLEN', @public_q)
  end

  def test_reclaim_takes_the_tail_onto_the_tail_as_lmove_right_right_does
    redis('DEL', @public_q, @private_list)
    redis('RPUSH', @private_list, 'a', 'b')
    redis('RPUSH', @public_q, 'existing')

    assert_equal 'b', reclaim_one
    assert_equal %w[existing b], redis('LRANGE', @public_q, 0, -1)
    assert_equal ['a'], redis('LRANGE', @private_list, 0, -1)
  end

  def test_reclaim_of_an_empty_list_returns_nil
    redis('DEL', @private_list)

    assert_nil reclaim_one
  end

  private

  def unit(private_queue: @private_list)
    Wurk::Fetcher::Reliable::UnitOfWork.new(queue: @public_q, queue_name: @queue, private_queue: private_queue,
                                            job: @payload, config: @config.default_capsule)
  end

  def reclaim_one
    @config.redis do |conn|
      Wurk::Lua::Loader.eval_cached(conn, :reliable_reclaim, keys: [@private_list, @public_q], argv: [])
    end
  end

  def redis(*command)
    @config.redis { |conn| conn.call(*command) }
  end
end
