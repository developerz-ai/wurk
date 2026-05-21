# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Drives Wurk::Batch against real Redis. Asserts on the Sidekiq Pro contract
# (docs/target/sidekiq-pro.md §2): BID shape, hash schema, jobs block atomic
# enqueue, callbacks registry, tag indexing, invalidation cascade.
#
# Parallel safety: every test scopes its own BID via `Process.pid:object_id`
# and cleans those keys in teardown. No test touches another's BIDs.
class BatchTest < Wurk::Test::UnitCase
  parallelize_me!

  BID_PATTERN = /\A[A-Za-z0-9_-]+\z/

  def setup
    super
    @pool = Wurk.configuration.redis_pool
    @class_name = "BatchJob@#{Process.pid}-#{object_id}"
    @queue     = "bq-#{Process.pid}-#{object_id}"
    @bids      = []
  end

  def teardown
    @pool.with do |conn|
      @bids.uniq.each do |bid|
        conn.call('UNLINK', *Wurk::Batch.keys_for(bid))
        conn.call('ZREM', 'batches', bid)
        conn.call('ZREM', 'dead-batches', bid)
      end
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue) if @queue
    end
  ensure
    super
  end

  # --- BID + ctor --------------------------------------------------------

  def test_new_assigns_url_safe_base64_bid
    batch = track(Wurk::Batch.new)

    assert_match BID_PATTERN, batch.bid
  end

  def test_new_assigns_distinct_bids
    a = track(Wurk::Batch.new)
    b = track(Wurk::Batch.new)

    refute_equal a.bid, b.bid
  end

  def test_reopen_with_bid_preserves_identity
    a = track(Wurk::Batch.new)
    a.description = 'overall'
    a.jobs { perform_one(a) }

    reopened = Wurk::Batch.new(a.bid)
    track(reopened)

    assert_equal a.bid, reopened.bid
    assert_equal 'overall', reopened.description
  end

  def test_fresh_batch_is_mutable
    assert_predicate track(Wurk::Batch.new), :mutable?
  end

  def test_reopened_batch_is_not_mutable
    a = track(Wurk::Batch.new)
    a.jobs { perform_one(a) }

    refute_predicate track(Wurk::Batch.new(a.bid)), :mutable?
  end

  # --- attribute setters -------------------------------------------------

  def test_description_round_trips
    batch = track(Wurk::Batch.new)
    batch.description = 'overall fulfillment'
    batch.jobs { perform_one(batch) }

    reopened = track(Wurk::Batch.new(batch.bid))

    assert_equal 'overall fulfillment', reopened.description
  end

  def test_callback_queue_round_trips
    batch = track(Wurk::Batch.new)
    batch.callback_queue = 'cb-q'
    batch.jobs { perform_one(batch) }

    reopened = track(Wurk::Batch.new(batch.bid))

    assert_equal 'cb-q', reopened.callback_queue
  end

  def test_tags_round_trip
    batch = track(Wurk::Batch.new)
    batch.tags = ['customer:42', 'job:fulfill']
    batch.jobs { perform_one(batch) }

    reopened = track(Wurk::Batch.new(batch.bid))

    assert_equal ['customer:42', 'job:fulfill'], reopened.tags
  end

  def test_tags_coerces_to_strings
    batch = track(Wurk::Batch.new)
    batch.tags = [:sym, 7]

    assert_equal %w[sym 7], batch.tags
  end

  # --- #jobs block -------------------------------------------------------

  def test_jobs_block_increments_total_and_pending
    batch = track(Wurk::Batch.new)
    batch.jobs { 3.times { perform_one(batch) } }

    assert_equal 3, Wurk::Batch::Status.new(batch.bid).total
    assert_equal 3, Wurk::Batch::Status.new(batch.bid).pending
  end

  def test_jobs_block_lpushes_to_target_queue
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }

    assert_equal(1, @pool.with { |c| c.call('LLEN', "queue:#{@queue}") })
  end

  def test_jobs_block_payload_carries_bid
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }

    payload = JSON.parse(@pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.first)

    assert_equal batch.bid, payload['bid']
  end

  def test_jobs_block_registers_jid_into_live_set
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }

    jid = JSON.parse(@pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.first)['jid']

    assert_equal(1, @pool.with { |c| c.call('SISMEMBER', "b-#{batch.bid}-jids", jid) })
  end

  def test_jobs_block_indexes_batch_in_global_set
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }

    assert_includes @pool.with { |c| c.call('ZRANGE', 'batches', 0, -1) }, batch.bid
  end

  def test_jobs_block_indexes_each_tag
    batch = track(Wurk::Batch.new)
    batch.tags = ['customer:42']
    batch.jobs { perform_one(batch) }

    assert_includes @pool.with { |c| c.call('SMEMBERS', 'tags:customer:42') }, batch.bid
  end

  def test_empty_jobs_block_enqueues_marker_job
    batch = track(Wurk::Batch.new)
    batch.jobs {} # rubocop:disable Lint/EmptyBlock

    assert_operator Wurk::Batch::Status.new(batch.bid).total, :>=, 1
  end

  def test_jobs_block_raises_without_block
    batch = track(Wurk::Batch.new)

    assert_raises(ArgumentError) { batch.jobs }
  end

  def test_repeated_jobs_block_accumulates_total
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }
    batch.jobs { perform_one(batch) }

    assert_equal 2, Wurk::Batch::Status.new(batch.bid).total
  end

  # --- include? / remove_jobs -------------------------------------------

  def test_include_returns_true_for_member_jid
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }
    jid = JSON.parse(@pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.first)['jid']

    assert_includes batch, jid
  end

  def test_include_returns_false_for_unknown_jid
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }

    refute_includes batch, 'deadbeef'
  end

  def test_remove_jobs_decrements_total_and_pending # rubocop:disable Metrics/AbcSize
    batch = track(Wurk::Batch.new)
    batch.jobs { 3.times { perform_one(batch) } }
    jids = queued_jids

    removed = batch.remove_jobs(jids[0], jids[1])

    assert_equal 2, removed
    assert_equal 1, Wurk::Batch::Status.new(batch.bid).total
    assert_equal 1, Wurk::Batch::Status.new(batch.bid).pending
  end

  def test_remove_jobs_returns_zero_for_unknown
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }

    assert_equal 0, batch.remove_jobs('aaa', 'bbb')
  end

  # --- invalidation ------------------------------------------------------

  def test_invalidate_all_sets_flag
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }
    batch.invalidate_all

    refute_predicate batch, :valid?
  end

  def test_invalidate_all_clears_live_jids_set
    batch = track(Wurk::Batch.new)
    batch.jobs { 2.times { perform_one(batch) } }
    batch.invalidate_all

    assert_equal(0, @pool.with { |c| c.call('SCARD', "b-#{batch.bid}-jids") })
  end

  def test_valid_default_true
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }

    assert_predicate batch, :valid?
  end

  # --- callbacks ---------------------------------------------------------

  def test_on_registers_callback
    batch = track(Wurk::Batch.new)
    batch.on(:success, 'MyCallback', 'k' => 1)
    batch.jobs { perform_one(batch) }

    persisted = JSON.parse(@pool.with { |c| c.call('HGET', "b-#{batch.bid}", 'callbacks') })

    assert_equal [['success', 'MyCallback', { 'k' => 1 }]], persisted
  end

  def test_on_accepts_class_target
    klass = Class.new { def self.name = 'BatchTestCb' }
    batch = track(Wurk::Batch.new)
    batch.on(:complete, klass)
    batch.jobs { perform_one(batch) }

    persisted = JSON.parse(@pool.with { |c| c.call('HGET', "b-#{batch.bid}", 'callbacks') })

    assert_equal 'BatchTestCb', persisted.first[1]
  end

  def test_on_rejects_unknown_event
    batch = track(Wurk::Batch.new)

    assert_raises(ArgumentError) { batch.on(:nope, 'X') }
  end

  def test_on_rejects_non_hash_options
    batch = track(Wurk::Batch.new)

    assert_raises(ArgumentError) { batch.on(:success, 'X', 'not-a-hash') }
  end

  # --- expires_in --------------------------------------------------------

  def test_expires_in_returns_self
    batch = track(Wurk::Batch.new)

    assert_same batch, batch.expires_in(60)
  end

  # --- parent / parent_bid ----------------------------------------------

  def test_nested_batch_records_parent_bid
    parent = track(Wurk::Batch.new)
    child  = nil
    parent.jobs do
      child = Wurk::Batch.new
      track(child)
      child.jobs { perform_one(child) }
    end

    reopened = track(Wurk::Batch.new(child.bid))

    assert_equal parent.bid, reopened.parent_bid
  end

  def test_status_returns_status_object
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }

    assert_kind_of Wurk::Batch::Status, batch.status
  end

  private

  def track(batch)
    @bids << batch.bid
    batch
  end

  # Test stub — push through Wurk::Client so client middleware runs and
  # BATCH_PUSH atomically registers each push. `bid` propagates from the
  # active Thread.current[Wurk::Batch::THREAD_KEY] (set inside #jobs).
  def perform_one(_batch)
    Wurk::Client.push('class' => @class_name, 'args' => [], 'queue' => @queue)
  end

  def queued_jids
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |s| JSON.parse(s)['jid'] }
  end
end
