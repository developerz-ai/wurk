# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Drives Wurk::Batch::Status against real Redis. Asserts on the spec
# (docs/target/sidekiq-pro.md §2.5): hash field reads, derived booleans
# (complete?, invalidated?), data/JSON shape, delete behaviour.
class BatchStatusTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @pool = Wurk.configuration.redis_pool
    @bid  = "test-#{Process.pid}-#{object_id}"
    @qname = "bsq-#{Process.pid}-#{object_id}"
  end

  def teardown
    @pool.with do |conn|
      conn.call('UNLINK', *Wurk::Batch.keys_for(@bid))
      conn.call('ZREM', 'batches', @bid)
      conn.call('ZREM', 'dead-batches', @bid)
      conn.call('DEL', "queue:#{@qname}")
    end
  ensure
    super
  end

  # --- ctor --------------------------------------------------------------

  def test_initialize_requires_non_empty_bid
    assert_raises(ArgumentError) { Wurk::Batch::Status.new(nil) }
    assert_raises(ArgumentError) { Wurk::Batch::Status.new('') }
  end

  def test_bid_round_trips
    seed_batch

    assert_equal @bid, Wurk::Batch::Status.new(@bid).bid
  end

  # --- numeric counters --------------------------------------------------

  def test_total_pending_failures_read_hash_fields
    seed_batch(total: 5, pending: 3, failures: 1)
    status = Wurk::Batch::Status.new(@bid)

    assert_equal 5, status.total
    assert_equal 3, status.pending
    assert_equal 1, status.failures
  end

  def test_total_missing_field_returns_zero
    seed_batch(total: nil, pending: nil)

    assert_equal 0, Wurk::Batch::Status.new(@bid).total
  end

  # --- timestamps --------------------------------------------------------

  def test_created_at_returns_float
    seed_batch(created_at: '1700000000.5')

    assert_in_delta 1_700_000_000.5, Wurk::Batch::Status.new(@bid).created_at, 0.01
  end

  def test_complete_at_nil_when_absent
    seed_batch

    assert_nil Wurk::Batch::Status.new(@bid).complete_at
  end

  def test_complete_at_returns_float_when_set
    seed_batch(complete_at: '1700001000.0')

    assert_in_delta 1_700_001_000.0, Wurk::Batch::Status.new(@bid).complete_at, 0.01
  end

  # --- complete? & invalidated? -----------------------------------------

  def test_complete_false_when_jids_remain
    seed_batch(total: 2, pending: 2)
    @pool.with { |c| c.call('SADD', "b-#{@bid}-jids", 'A', 'B') }

    refute_predicate Wurk::Batch::Status.new(@bid), :complete?
  end

  def test_complete_true_when_jids_drained
    seed_batch(total: 2, pending: 0)

    assert_predicate Wurk::Batch::Status.new(@bid), :complete?
  end

  def test_complete_true_when_hash_flag_set
    seed_batch
    @pool.with { |c| c.call('HSET', "b-#{@bid}", 'complete', '1') }

    assert_predicate Wurk::Batch::Status.new(@bid), :complete?
  end

  def test_invalidated_false_default
    seed_batch

    refute_predicate Wurk::Batch::Status.new(@bid), :invalidated?
  end

  def test_invalidated_true_when_flag_set
    seed_batch
    @pool.with { |c| c.call('HSET', "b-#{@bid}", 'invalidated', '1') }

    assert_predicate Wurk::Batch::Status.new(@bid), :invalidated?
  end

  # --- jid arrays --------------------------------------------------------

  def test_failed_jids_reads_set
    seed_batch
    @pool.with { |c| c.call('SADD', "b-#{@bid}-failed", 'jidA', 'jidB') }

    assert_equal %w[jidA jidB].sort, Wurk::Batch::Status.new(@bid).failed_jids.sort
  end

  def test_dead_jids_reads_set
    seed_batch
    @pool.with { |c| c.call('SADD', "b-#{@bid}-died", 'jidX') }

    assert_equal ['jidX'], Wurk::Batch::Status.new(@bid).dead_jids
  end

  def test_failed_jids_empty_when_set_missing
    seed_batch

    assert_empty Wurk::Batch::Status.new(@bid).failed_jids
  end

  # --- tags --------------------------------------------------------------

  def test_tags_round_trips_json
    seed_batch(tags: ['customer:1', 'kind:fulfill'].to_json)

    assert_equal ['customer:1', 'kind:fulfill'], Wurk::Batch::Status.new(@bid).tags
  end

  def test_tags_empty_when_missing
    seed_batch

    assert_empty Wurk::Batch::Status.new(@bid).tags
  end

  # --- child_count -------------------------------------------------------

  def test_child_count_reads_kids_set
    seed_batch
    @pool.with { |c| c.call('SADD', "b-#{@bid}-kids", 'child1', 'child2') }

    assert_equal 2, Wurk::Batch::Status.new(@bid).child_count
  end

  # --- #data hash --------------------------------------------------------

  def test_data_includes_bid
    seed_batch

    assert_equal @bid, Wurk::Batch::Status.new(@bid).data['bid']
  end

  def test_data_keys_match_spec_surface
    seed_batch
    keys = Wurk::Batch::Status.new(@bid).data.keys.sort
    required = %w[total pending failures complete invalidated tags]

    required.each { |k| assert_includes keys, k }
  end

  # --- #delete -----------------------------------------------------------

  def test_delete_unlinks_all_keys
    seed_batch
    @pool.with do |c|
      c.call('SADD', "b-#{@bid}-jids", 'X')
      c.call('SADD', "b-#{@bid}-kids", 'child')
      c.call('ZADD', 'batches', '1.0', @bid)
    end

    Wurk::Batch::Status.new(@bid).delete

    assert_equal(0, @pool.with { |c| c.call('EXISTS', "b-#{@bid}") })
    assert_equal(0, @pool.with { |c| c.call('EXISTS', "b-#{@bid}-jids") })
    refute_includes @pool.with { |c| c.call('ZRANGE', 'batches', 0, -1) }, @bid
  end

  # --- #join (smoke) -----------------------------------------------------

  def test_join_returns_immediately_when_complete
    seed_batch(total: 1, pending: 0)
    # No jids set → complete? is true → join returns without sleeping.
    Wurk::Batch::Status.new(@bid).join
  end

  private

  def seed_batch(fields = {})
    defaults = {
      'created_at' => Time.now.to_f.to_s,
      'description' => 'test',
      'callback_queue' => 'default',
      'tags' => '[]',
      'callbacks' => '[]',
      'total' => '0',
      'pending' => '0',
      'failures' => '0'
    }
    merged = defaults.merge(fields.transform_keys(&:to_s)).compact
    @pool.with do |conn|
      conn.call('HSET', "b-#{@bid}", *merged.flatten) unless merged.empty?
    end
  end
end
