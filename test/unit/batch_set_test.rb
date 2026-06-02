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
      conn.call('UNLINK', "tags:#{@big_tag}") if @big_tag
    end
  ensure
    super
  end

  # --- BatchSet ---------------------------------------------------------

  def test_size_returns_count_of_indexed_batches
    # `batches` ZSET is globally shared — siblings may both add AND remove
    # entries between our reads. A `pre + 2` snapshot-and-diff is brittle:
    # if a sibling's teardown ZREMs between snapshot and re-read, the diff
    # underflows. Instead: verify our 2 seeded bids are members of the set,
    # and that `size` is at least their count.
    bids = seed(2)
    set  = Wurk::BatchSet.new
    scores = @pool.with do |c|
      bids.map { |bid| c.call('ZSCORE', 'batches', bid) }
    end

    refute_includes scores, nil, 'expected all seeded bids in `batches` ZSET'
    assert_operator set.size, :>=, bids.size
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

  # PAGE_SIZE is 100 — seeding 101 of our own bids forces `each` past the
  # first ZRANGE page (the `bids.size < PAGE_SIZE` else side: keep looping).
  # All 101 must come back even though they straddle the page boundary.
  def test_each_pages_past_page_size
    seeded = seed(Wurk::BatchSet::PAGE_SIZE + 1).to_set
    yielded = Set.new
    Wurk::BatchSet.new.each { |status| yielded << status.bid if seeded.include?(status.bid) }

    assert_equal seeded, yielded
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

  # A tag set big enough that SSCAN can't drain in one COUNT=100 pass forces
  # the loop through a non-'0' cursor (the `cursor == '0'` else side: keep
  # scanning). Every seeded member must be yielded exactly once.
  def test_scan_tags_continues_across_cursor_pages
    tag = "bigtag-#{@ns}"
    @big_tag = tag
    members = (0...1000).map { |i| "m-#{i}" }
    @pool.with { |c| c.call('SADD', "tags:#{tag}", *members) }

    found = []
    Wurk::BatchSet.new.scan_tags(tag) { |b| found << b }

    assert_equal members.sort, found.sort
    assert_equal members.size, found.uniq.size
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
