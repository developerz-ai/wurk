# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Every Redis key a batch owns must carry a TTL from the moment it exists.
# `#jobs` only ever stamped `b-<bid>`, so a batch that was abandoned or
# invalidated — never acked, never successful — leaked its `-jids`/`-failed`/
# `-died`/`-kids`/`-pkids` sets forever. The stamp now happens at each creation
# site (BATCH_PUSH / BATCH_SCHEDULE / the acks / Batch#link_to_parent) with
# `EXPIRE ... NX`, so a live batch's clock and the shorter post-success linger
# window still win. Spec: docs/target/sidekiq-pro.md §2.8 (30d while pending).
#
# Parallel safety: every BID + queue is scoped to PID:object_id and torn down.
class BatchKeyTtlTest < Wurk::Test::UnitCase
  parallelize_me!

  DEFAULT_TTL = Wurk::Batch::DEFAULT_EXPIRY_SECONDS

  def setup
    super
    @pool       = Wurk.configuration.redis_pool
    @class_name = "BatchTtlJob@#{Process.pid}-#{object_id}"
    @queue      = "btq-#{Process.pid}-#{object_id}"
    @cbq        = "btcb-#{Process.pid}-#{object_id}"
    @bids       = []
  end

  def teardown
    @pool.with do |conn|
      @bids.uniq.each do |bid|
        conn.call('UNLINK', *Wurk::Batch.keys_for(bid))
        conn.call('ZREM', 'batches', bid)
        conn.call('ZREM', 'dead-batches', bid)
      end
      [@queue, @cbq].each do |q|
        conn.call('DEL', "queue:#{q}")
        conn.call('SREM', 'queues', q)
      end
    end
  ensure
    super
  end

  # --- creation sites ----------------------------------------------------

  def test_push_stamps_the_live_jids_set
    batch = new_batch
    batch.jobs { perform_one }

    assert_default_ttl "b-#{batch.bid}-jids"
  end

  def test_scheduled_push_stamps_the_live_jids_set
    batch = new_batch
    batch.jobs { perform_one(at: Time.now.to_f + 3600) }

    assert_default_ttl "b-#{batch.bid}-jids"
  end

  def test_failed_ack_stamps_the_failed_set
    batch = new_batch
    batch.jobs { perform_one }
    fail_job(batch.bid, jid_for(batch.bid))

    assert_default_ttl "b-#{batch.bid}-failed"
  end

  # Driven through the raw script, not DeathHandler.call: the handler's own
  # restamp sweep would mask a missing stamp inside BATCH_ACK_COMPLETE, and the
  # whole point of stamping in the script is that a process dying between the
  # ack and that sweep still leaves no clock-less key.
  def test_death_ack_stamps_the_died_set
    batch = new_batch
    batch.jobs { perform_one }
    ack_complete(batch.bid, jid_for(batch.bid))

    assert_default_ttl "b-#{batch.bid}-died"
  end

  def test_nested_batch_stamps_parent_kids_sets
    parent, = nested

    assert_default_ttl "b-#{parent.bid}-kids"
    assert_default_ttl "b-#{parent.bid}-pkids"
  end

  # The headline case: a batch nobody ever finishes. Nothing downstream
  # (apply_linger, the death restamp) runs for it, so every key it created has
  # to have been stamped on the way in.
  def test_abandoned_batch_leaves_no_key_without_a_ttl
    parent, child = nested
    fail_job(child.bid, jid_for(child.bid))
    ack_complete(child.bid, jid_for(child.bid))

    assert_batch_keys_clocked(parent, child)
  end

  # --- NX: never clobber a shorter window --------------------------------

  def test_push_keeps_a_per_batch_expires_in_override
    batch = new_batch
    batch.expires_in(300)
    batch.jobs { perform_one }

    assert_operator ttl("b-#{batch.bid}"), :<=, 300
    assert_operator ttl("b-#{batch.bid}"), :>, 240
  end

  def test_push_does_not_extend_a_shorter_window_on_the_jids_set
    batch = new_batch
    batch.jobs { perform_one }
    @pool.with { |c| c.call('EXPIRE', "b-#{batch.bid}-jids", 120) }
    batch.jobs { perform_one }

    assert_operator ttl("b-#{batch.bid}-jids"), :<=, 120
    assert_operator ttl("b-#{batch.bid}-jids"), :>, 60
  end

  # --- resurrection ------------------------------------------------------

  # A retry or scheduled promotion re-pushing a job after the batch expired
  # recreates `b-<bid>` (HINCRBY) and `b-<bid>-jids` (SADD). Before the stamp
  # those came back with no clock and stayed forever.
  def test_push_reclocks_a_batch_whose_keys_expired
    batch = new_batch
    batch.jobs { perform_one }
    jid = jid_for(batch.bid)
    @pool.with { |c| c.call('UNLINK', "b-#{batch.bid}", "b-#{batch.bid}-jids") }

    Wurk::Client.push('class' => @class_name, 'args' => [], 'queue' => @queue, 'bid' => batch.bid, 'jid' => jid)

    assert_default_ttl "b-#{batch.bid}"
    assert_default_ttl "b-#{batch.bid}-jids"
  end

  def test_callback_event_record_reclocks_a_batch_whose_hash_expired
    batch = new_batch
    batch.jobs { perform_one }
    @pool.with { |c| c.call('UNLINK', "b-#{batch.bid}") }

    Wurk::Batch::Callbacks.record_event(batch.bid, 'complete_at')

    assert_default_ttl "b-#{batch.bid}"
  end

  # --- keys_for covers the callback dedup markers ------------------------

  def test_keys_for_includes_callback_dedup_markers
    keys = Wurk::Batch.keys_for('abc')

    %w[complete success death].each { |event| assert_includes keys, "b-abc-#{event}" }
  end

  def test_delete_removes_the_callback_dedup_markers
    batch = new_batch
    batch.jobs { perform_one }
    ack_success(batch.bid, jid_for(batch.bid))

    Wurk::Batch::Status.new(batch.bid).delete

    %w[complete success].each do |event|
      assert_equal 0, @pool.with { |c| c.call('EXISTS', "b-#{batch.bid}-#{event}") },
                   "b-<bid>-#{event} outlived Status#delete"
    end
  end

  # Post-success the dedup markers expire with the rest of the batch instead of
  # holding their own 30d clock — by then the hash carrying the callback specs
  # is gone too, so nothing could re-fire off them anyway.
  def test_linger_shortens_the_callback_dedup_markers
    batch = new_batch
    batch.jobs { perform_one }
    ack_success(batch.bid, jid_for(batch.bid))

    assert_operator ttl("b-#{batch.bid}-success"), :<=, Wurk::Batch::POST_SUCCESS_EXPIRY_SECONDS
    assert_operator ttl("b-#{batch.bid}-success"), :>, Wurk::Batch::POST_SUCCESS_EXPIRY_SECONDS - 60
  end

  private

  def new_batch
    batch = Wurk::Batch.new
    batch.callback_queue = @cbq
    @bids << batch.bid
    batch
  end

  # Parent batch holding one job plus a nested child batch (one job) — the
  # only path that creates the parent's `-kids`/`-pkids` sets.
  def nested
    parent = new_batch
    child = nil
    parent.jobs do
      perform_one
      child = new_batch
      child.jobs { perform_one }
    end
    [parent, child]
  end

  # Pushed through Wurk::Client so the batch client middleware stamps the bid
  # from Thread.current[Wurk::Batch::THREAD_KEY] and routes through the Lua.
  def perform_one(at: nil)
    job = { 'class' => @class_name, 'args' => [], 'queue' => @queue }
    job['at'] = at if at
    Wurk::Client.push(job)
  end

  def ack_success(bid, jid)
    mw = Wurk::Batch::ServerMiddleware.new
    mw.config = Wurk.configuration
    mw.call(nil, { 'bid' => bid, 'jid' => jid }, @queue) {}
  end

  def fail_job(bid, jid)
    mw = Wurk::Batch::ServerMiddleware.new
    mw.config = Wurk.configuration
    mw.call(nil, { 'bid' => bid, 'jid' => jid }, @queue) { raise 'boom' }
  rescue RuntimeError => e
    raise unless e.message == 'boom'
  end

  def ack_complete(bid, jid)
    @pool.with do |conn|
      Wurk::Lua::Loader.eval_cached(
        conn,
        :batch_ack_complete,
        keys: ["b-#{bid}", "b-#{bid}-jids", "b-#{bid}-died", "b-#{bid}-failed"],
        argv: [jid, Wurk::Batch::DEFAULT_EXPIRY_SECONDS]
      )
    end
  end

  def jid_for(bid)
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }
         .map { |s| JSON.parse(s) }
         .find { |j| j['bid'] == bid }
         .fetch('jid')
  end

  def ttl(key)
    @pool.with { |c| c.call('TTL', key) }
  end

  def keys_matching(pattern)
    cursor = '0'
    found  = []
    loop do
      cursor, chunk = @pool.with { |c| c.call('SCAN', cursor, 'MATCH', pattern, 'COUNT', 100) }
      found.concat(chunk)
      break if cursor == '0'
    end
    found
  end

  # SCANs every key the two batches own and asserts none of them lost its
  # clock. The `-pkids` check guards against a vacuous pass: an empty scan
  # would satisfy the `assert_empty` on its own.
  def assert_batch_keys_clocked(parent, child)
    keys      = [parent, child].flat_map { |b| keys_matching("b-#{b.bid}*") }
    clockless = keys.reject { |key| ttl(key).positive? }

    assert_includes keys, "b-#{parent.bid}-pkids"
    assert_empty clockless, "batch keys with no TTL: #{clockless.join(', ')}"
  end

  def assert_default_ttl(key)
    actual = ttl(key)

    assert_operator actual, :<=, DEFAULT_TTL, "#{key} TTL #{actual} exceeds the 30d default"
    assert_operator actual, :>, DEFAULT_TTL - 60, "#{key} has no default TTL (got #{actual})"
  end
end
