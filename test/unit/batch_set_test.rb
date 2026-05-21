# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Drives Wurk::BatchSet + Wurk::Batch::DeadSet against real Redis. Asserts
# on the discovery surface (docs/target/sidekiq-pro.md §2.7): size, each
# yielding Status, scan_tags by tag → BID.
class BatchSetTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @pool = Wurk.configuration.redis_pool
    @ns   = "bset-#{Process.pid}-#{object_id}"
    @bids = []
  end

  def teardown
    @pool.with do |conn|
      @bids.uniq.each do |bid|
        conn.call('UNLINK', *Wurk::Batch.keys_for(bid))
        conn.call('ZREM', 'batches', bid)
        conn.call('ZREM', 'dead-batches', bid)
        conn.call('SREM', "tags:#{tag_for(bid)}", bid)
      end
      tag_for_each_seeded { |tag| conn.call('UNLINK', "tags:#{tag}") }
    end
  ensure
    super
  end

  # --- BatchSet ---------------------------------------------------------

  def test_size_returns_count_of_indexed_batches
    pre = Wurk::BatchSet.new.size
    seed(2)

    assert_equal pre + 2, Wurk::BatchSet.new.size
  end

  def test_each_yields_status_objects
    seed(1)
    matched = nil
    Wurk::BatchSet.new.each do |status|
      matched = status if @bids.include?(status.bid)
    end

    refute_nil matched
    assert_kind_of Wurk::Batch::Status, matched
  end

  def test_each_returns_enumerator_without_block
    assert_kind_of Enumerator, Wurk::BatchSet.new.each
  end

  # --- scan_tags --------------------------------------------------------

  def test_scan_tags_yields_bids_for_tag
    bid = seed(1).first
    tag = tag_for(bid)
    found = []
    Wurk::BatchSet.new.scan_tags(tag) { |b| found << b }

    assert_includes found, bid
  end

  def test_scan_tags_no_match_yields_nothing
    found = []
    Wurk::BatchSet.new.scan_tags("absent-#{@ns}") { |b| found << b }

    assert_empty found
  end

  def test_scan_tags_returns_enumerator_without_block
    assert_kind_of Enumerator, Wurk::BatchSet.new.scan_tags('x')
  end

  # --- DeadSet ----------------------------------------------------------

  def test_dead_set_is_a_batch_set
    assert_kind_of Wurk::BatchSet, Wurk::Batch::DeadSet.new
  end

  def test_dead_set_uses_dead_batches_zset
    bid = "dead-#{@ns}-1"
    @pool.with do |c|
      c.call('ZADD', 'dead-batches', '1.0', bid)
      c.call('HSET', "b-#{bid}", 'total', '1')
    end
    @bids << bid
    found = Wurk::Batch::DeadSet.new.map(&:bid)

    assert_includes found, bid
  ensure
    @pool.with { |c| c.call('ZREM', 'dead-batches', bid) }
  end

  private

  def seed(count)
    count.times.map do
      bid = "#{@ns}-#{SecureRandom.hex(4)}"
      @bids << bid
      tag = tag_for(bid)
      @pool.with do |c|
        c.call('HSET', "b-#{bid}", 'total', '1', 'pending', '0', 'tags', [tag].to_json)
        c.call('ZADD', 'batches', Time.now.to_f.to_s, bid)
        c.call('SADD', "tags:#{tag}", bid)
      end
      bid
    end
  end

  def tag_for(bid)
    "#{@ns}-tag-#{bid[-4..]}"
  end

  def tag_for_each_seeded
    @bids.each { |bid| yield tag_for(bid) }
  end
end
