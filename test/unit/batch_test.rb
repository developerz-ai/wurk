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
    @queue = "bq-#{Process.pid}-#{object_id}"
    # Tags must be per-test namespaced too — `tags:customer:42` is a shared
    # Redis Set; parallel tests touching it cross-contaminate.
    @tag_customer = "customer:42:#{Process.pid}:#{object_id}"
    @tag_job      = "job:fulfill:#{Process.pid}:#{object_id}"
    @bids         = []
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
      [@tag_customer, @tag_job].each { |tag| conn.call('UNLINK', "tags:#{tag}") }
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

  def test_callback_class_round_trips
    batch = track(Wurk::Batch.new)
    batch.callback_class = 'MyCallbacks'
    batch.jobs { perform_one(batch) }

    reopened = track(Wurk::Batch.new(batch.bid))

    assert_equal 'MyCallbacks', reopened.callback_class
  end

  def test_callback_class_accepts_a_class_and_stores_its_name
    klass = Class.new { def self.name = 'BatchTestCbClass' }
    batch = track(Wurk::Batch.new)
    batch.callback_class = klass

    assert_equal 'BatchTestCbClass', batch.callback_class
  end

  def test_callback_class_accepts_nil
    batch = track(Wurk::Batch.new)
    batch.callback_class = 'MyCallbacks'
    batch.callback_class = nil

    assert_nil batch.callback_class
  end

  def test_callback_class_rejects_a_value_that_names_nothing
    batch = track(Wurk::Batch.new)

    assert_raises(ArgumentError) { batch.callback_class = 42 }
  end

  def test_tags_round_trip
    batch = track(Wurk::Batch.new)
    batch.tags = [@tag_customer, @tag_job]
    batch.jobs { perform_one(batch) }

    reopened = track(Wurk::Batch.new(batch.bid))

    assert_equal [@tag_customer, @tag_job], reopened.tags
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
    batch.tags = [@tag_customer]
    batch.jobs { perform_one(batch) }

    assert_includes @pool.with { |c| c.call('SMEMBERS', "tags:#{@tag_customer}") }, batch.bid
  end

  def test_empty_jobs_block_enqueues_marker_job
    batch = track(Wurk::Batch.new)
    batch.jobs {}

    assert_operator Wurk::Batch::Status.new(batch.bid).total, :>=, 1
  end

  # A scheduled (`at`) job inside #jobs registers into the batch at creation via
  # BATCH_SCHEDULE: total/pending move now, the jid joins the live set, and the
  # payload waits in `schedule` (not the queue). Promotion later re-pushes it
  # through BATCH_PUSH's guard — jid already live → no double count.
  def test_scheduled_job_in_jobs_block_counts_and_registers
    at    = future_at
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one_scheduled(at) }

    assert_equal 1, Wurk::Batch::Status.new(batch.bid).total
    assert_equal 1, Wurk::Batch::Status.new(batch.bid).pending

    member, score = mine_in_schedule(batch.bid)

    refute_nil member, 'scheduled batched job must land in the `schedule` zset'
    assert_equal batch.bid, member['bid']
    assert_in_delta at, score.to_f, 0.01
    assert_equal(1, @pool.with { |c| c.call('SISMEMBER', "b-#{batch.bid}-jids", member['jid']) })
  end

  def test_scheduled_job_in_jobs_block_is_not_pushed_to_queue
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one_scheduled(future_at) }

    assert_equal(0, @pool.with { |c| c.call('LLEN', "queue:#{@queue}") })
  end

  # The empty-marker check keys off `total`; because BATCH_SCHEDULE moves it, a
  # scheduled-only block is NOT mistaken for empty. A misfire would BATCH_PUSH a
  # Batch::Empty marker → total would be 2.
  def test_scheduled_only_block_does_not_enqueue_empty_marker
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one_scheduled(future_at) }

    assert_equal 1, Wurk::Batch::Status.new(batch.bid).total
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

  def test_remove_jobs_decrements_total_and_pending
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

  def test_parent_returns_batch_when_parent_bid_present
    parent = track(Wurk::Batch.new)
    child  = nil
    parent.jobs do
      child = track(Wurk::Batch.new)
      child.jobs { perform_one(child) }
    end

    reopened = track(Wurk::Batch.new(child.bid))
    fetched_parent = reopened.parent

    assert_kind_of Wurk::Batch, fetched_parent
    assert_equal parent.bid, fetched_parent.bid
  end

  def test_parent_returns_nil_when_no_parent_bid
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }

    assert_nil track(Wurk::Batch.new(batch.bid)).parent
  end

  # --- linger setter -----------------------------------------------------

  def test_linger_setter_accepts_nil_before_flush
    batch = track(Wurk::Batch.new)
    batch.linger = nil

    assert_nil batch.linger
  end

  # --- remove_jobs edge --------------------------------------------------

  def test_remove_jobs_with_no_args_returns_zero
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }

    assert_equal 0, batch.remove_jobs
  end

  # --- callback_target type handling ------------------------------------

  def test_on_rejects_target_without_name
    batch = track(Wurk::Batch.new)

    assert_raises(ArgumentError) { batch.on(:success, 42) }
  end

  def test_on_accepts_arbitrary_object_responding_to_name
    target = Object.new
    def target.name = 'DuckTypedCb'
    batch = track(Wurk::Batch.new)
    batch.on(:complete, target)
    batch.jobs { perform_one(batch) }

    persisted = JSON.parse(@pool.with { |c| c.call('HGET', "b-#{batch.bid}", 'callbacks') })

    assert_equal 'DuckTypedCb', persisted.first[1]
  end

  # --- reopen parsing edges ---------------------------------------------

  def test_reopen_with_empty_tags_yields_empty_array
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }

    assert_empty track(Wurk::Batch.new(batch.bid)).tags
  end

  def test_reopen_with_non_array_callbacks_json_does_not_raise
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }
    # Persisted callbacks as a JSON object (not an Array): load_existing! must
    # coerce to [] rather than carrying a Hash or raising.
    @pool.with { |c| c.call('HSET', "b-#{batch.bid}", 'callbacks', '{"not":"an array"}') }

    reopened = track(Wurk::Batch.new(batch.bid))

    assert_equal batch.bid, reopened.bid
    # A coerced-empty callback registry leaves room to register a fresh one.
    assert_same reopened, reopened.on(:success, 'X')
  end

  def test_fetch_hash_array_branch_unreachable_under_resp3
    # fetch_hash's `else` (raw.each_slice(2).to_h) only runs when HGETALL
    # returns an Array, i.e. under RESP2. The pool negotiates RESP3 by default
    # (redis-client), where HGETALL always returns a Hash. Exercising the else
    # would require downgrading the protocol or mocking Redis — both barred by
    # the test rules (real Redis only). Documented as intentionally uncovered.
    sample =
      Wurk.redis do |c|
        c.call('HSET', "b-#{track(Wurk::Batch.new).bid}", 'k', 'v')
        c.call('HGETALL', "b-#{@bids.last}")
      end

    assert_kind_of Hash, sample
    skip 'fetch_hash array branch is unreachable under RESP3 (no mocking allowed)'
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

  # Scheduled sibling of perform_one — a future `at` routes through the batched
  # scheduled path (BATCH_SCHEDULE). `bid` is stamped by the client middleware
  # from the active Thread.current[Wurk::Batch::THREAD_KEY].
  def perform_one_scheduled(at)
    Wurk::Client.push('class' => @class_name, 'args' => [], 'queue' => @queue, 'at' => at)
  end

  def future_at
    ::Process.clock_gettime(::Process::CLOCK_REALTIME) + 600
  end

  # redis-client returns ZRANGE WITHSCORES as [[member, score], ...]. FLUSHDB
  # teardown + serial-within-class means `schedule` holds only this test's jobs.
  def mine_in_schedule(bid)
    @pool.with { |c| c.call('ZRANGE', 'schedule', 0, -1, 'WITHSCORES') }.filter_map do |member, score|
      payload = JSON.parse(member)
      [payload, score] if payload['bid'] == bid
    rescue JSON::ParserError
      next
    end.first
  end

  def queued_jids
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |s| JSON.parse(s)['jid'] }
  end
end
