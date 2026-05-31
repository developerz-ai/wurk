# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Drives the batch lifecycle end-to-end against real Redis: autoflush
# buffering, per-batch linger retention, the callback lifecycle
# (success / complete / death), nested death cascade, and per-callback
# rescue. Covers the edge cases in issue #17.
#
# Callbacks are enqueued as ordinary jobs on the batch's callback_queue;
# tests assert by inspecting that queue rather than executing the jobs.
#
# Parallel safety: every BID + queue + tag is scoped to PID:object_id and
# torn down. No test touches another's keys.
class BatchLifecycleTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @pool       = Wurk.configuration.redis_pool
    @class_name = "BatchLifeJob@#{Process.pid}-#{object_id}"
    @queue      = "blq-#{Process.pid}-#{object_id}"
    @cbq        = "blcb-#{Process.pid}-#{object_id}"
    @bids       = []
  end

  def teardown
    @pool.with do |conn|
      @bids.uniq.each do |bid|
        conn.call('UNLINK', *Wurk::Batch.keys_for(bid))
        # Callback dedup markers live outside keys_for (own 30d TTL).
        conn.call('UNLINK', "b-#{bid}-death", "b-#{bid}-success", "b-#{bid}-complete")
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

  # --- autoflush ---------------------------------------------------------

  def test_default_jobs_block_pushes_each_job_immediately
    batch = new_batch
    mid_total = nil
    batch.jobs do
      perform_one
      mid_total = total(batch)
    end

    assert_equal 1, mid_total
  end

  def test_autoflush_true_buffers_until_block_exit
    batch = new_batch
    batch.autoflush = true
    mid_total = nil
    batch.jobs do
      3.times { perform_one }
      mid_total = total(batch)
    end

    assert_equal 0, mid_total, 'jobs must stay buffered inside the block'
    assert_equal 3, total(batch)
  end

  def test_autoflush_integer_flushes_every_n_jobs
    batch = new_batch
    batch.autoflush = 2
    totals = []
    batch.jobs { 4.times { perform_one; totals << total(batch) } } # rubocop:disable Style/Semicolon

    assert_equal [0, 2, 2, 4], totals
  end

  def test_autoflush_empty_block_still_enqueues_marker
    batch = new_batch
    batch.autoflush = true
    batch.jobs {} # rubocop:disable Lint/EmptyBlock

    assert_operator total(batch), :>=, 1
  end

  def test_autoflush_invalid_value_raises_argument_error
    batch = new_batch
    [0, -1, '5', 2.5].each do |bad|
      batch.autoflush = bad
      err = assert_raises(ArgumentError) { batch.jobs { perform_one } }
      assert_match(/autoflush/, err.message)
    end
  end

  def test_autoflush_integer_bounds_bulk_push_pipeline
    batch = new_batch
    batch.autoflush = 2
    totals = []
    batch.jobs do
      Wurk::Client.push_bulk('class' => @class_name, 'queue' => @queue, 'args' => Array.new(6) { [] })
      totals << total(batch)
    end

    # 6 items at N=2 must flush 3 pipelines; total after the block sees them all.
    assert_equal 6, totals.last
    assert_equal 6, total(batch)
  end

  # --- linger ------------------------------------------------------------

  def test_success_applies_default_linger_retention
    ttl = ttl_after_success(new_batch)

    assert_operator ttl, :<=, Wurk::Batch::POST_SUCCESS_EXPIRY_SECONDS
    assert_operator ttl, :>, Wurk::Batch::POST_SUCCESS_EXPIRY_SECONDS - 60
  end

  def test_success_applies_per_batch_linger_override
    batch = new_batch
    batch.linger = 120
    ttl = ttl_after_success(batch)

    assert_operator ttl, :<=, 120
    assert_operator ttl, :>, 60
  end

  def test_linger_round_trips_on_reopen
    batch = new_batch
    batch.linger = 300
    batch.jobs { perform_one }

    assert_equal 300, Wurk::Batch.new(batch.bid).linger
  end

  def test_linger_assigned_after_flush_persists_to_redis
    batch = new_batch
    batch.jobs { perform_one }
    Wurk::Batch.new(batch.bid).linger = 240
    ack_success(batch.bid, jid_for(@queue, batch.bid))
    ttl = @pool.with { |c| c.call('TTL', "b-#{batch.bid}") }

    assert_operator ttl, :<=, 240
    assert_operator ttl, :>, 120
  end

  # --- callback lifecycle ------------------------------------------------

  def test_success_and_complete_fire_when_all_jobs_succeed
    batch = new_batch(success: 'S', complete: 'C')
    batch.jobs { perform_one }
    ack_success(batch.bid, jid_for(@queue, batch.bid))

    assert_equal 1, callbacks_fired(event: 'success', bid: batch.bid)
    assert_equal 1, callbacks_fired(event: 'complete', bid: batch.bid)
  end

  def test_complete_fires_but_success_does_not_on_death
    batch = new_batch(success: 'S', complete: 'C', death: 'D')
    batch.jobs { perform_one }
    kill(batch.bid, jid_for(@queue, batch.bid))

    assert_equal 1, callbacks_fired(event: 'complete', bid: batch.bid)
    assert_equal 0, callbacks_fired(event: 'success', bid: batch.bid)
  end

  def test_death_fires_exactly_once_across_multiple_deaths
    batch = new_batch(death: 'D')
    batch.jobs { 2.times { perform_one } }
    jids_for(@queue, batch.bid).each { |jid| kill(batch.bid, jid) }

    assert_equal 1, callbacks_fired(event: 'death', bid: batch.bid)
  end

  # --- nested death cascade ----------------------------------------------

  def test_child_death_fires_parent_death_callback_exactly_once
    parent, child = nested(parent_cbs: { death: 'ParentDeath' }, child_cbs: { death: 'ChildDeath' })
    kill(child.bid, jid_for(@queue, child.bid))

    assert_equal 1, callbacks_fired(event: 'death', bid: parent.bid)
    assert_dead parent.bid, child.bid
  end

  def test_child_death_suppresses_parent_success
    parent, child = nested(parent_cbs: { success: 'ParentSuccess', death: 'ParentDeath' })

    # Child dies first, then the parent's own job succeeds — success must
    # stay suppressed because the subtree had a death.
    kill(child.bid, jid_for(@queue, child.bid))
    ack_success(parent.bid, jid_for(@queue, parent.bid))

    assert_equal 0, callbacks_fired(event: 'success', bid: parent.bid)
    assert_equal 1, callbacks_fired(event: 'death', bid: parent.bid)
  end

  def test_parent_success_stays_suppressed_after_death_dedup_key_expires
    parent, child = nested(parent_cbs: { success: 'ParentSuccess', death: 'ParentDeath' })
    kill(child.bid, jid_for(@queue, child.bid))
    # Simulate the b-<bid>-death dedup marker expiring while the parent is
    # still open — durable `death=1` on b-<bid> must still gate :success.
    @pool.with { |c| c.call('DEL', "b-#{parent.bid}-death") }
    ack_success(parent.bid, jid_for(@queue, parent.bid))

    assert_equal 0, callbacks_fired(event: 'success', bid: parent.bid)
  end

  def test_deep_death_cascades_through_every_ancestor
    grand, parent, child = three_deep
    kill(child.bid, jid_for(@queue, child.bid))

    assert_equal 1, callbacks_fired(event: 'death', bid: grand.bid)
    assert_dead grand.bid, parent.bid
  end

  # --- per-callback rescue ----------------------------------------------

  def test_failing_callback_enqueue_does_not_strand_remaining_callbacks
    batch = new_batch(complete: 'CbA')
    batch.on(:complete, 'CbB')
    batch.jobs { perform_one }

    attempted = []
    raising_push = lambda do |item|
      attempted << item['args'][1]
      raise 'boom' if attempted.size == 1
    end
    with_push_override(raising_push) { Wurk::Batch::Callbacks.fire_complete(batch.bid) }

    assert_equal %w[CbA CbB], attempted, 'both callbacks attempted despite the first raising'
  end

  private

  def track(batch)
    @bids << batch.bid
    batch
  end

  # Fresh batch scoped to this test's callback queue, with the given
  # event => target callbacks registered.
  def new_batch(**callbacks)
    batch = track(Wurk::Batch.new)
    batch.callback_queue = @cbq
    callbacks.each { |event, target| batch.on(event, target) }
    batch
  end

  # Parent batch holding one direct job plus a nested child batch (one job).
  def nested(parent_cbs: {}, child_cbs: {})
    parent = new_batch(**parent_cbs)
    child = nil
    parent.jobs do
      perform_one
      child = new_batch(**child_cbs)
      child.jobs { perform_one }
    end
    [parent, child]
  end

  def three_deep
    grand = new_batch(death: 'GrandDeath')
    parent = child = nil
    grand.jobs do
      perform_one
      parent = new_batch
      parent.jobs do
        perform_one
        child = new_batch
        child.jobs { perform_one }
      end
    end
    [grand, parent, child]
  end

  # Push through Wurk::Client so the batch client middleware runs and the
  # active Thread.current[Wurk::Batch::THREAD_KEY] (set inside #jobs) stamps
  # the bid + routes through BATCH_PUSH (or the autoflush buffer).
  def perform_one
    Wurk::Client.push('class' => @class_name, 'args' => [], 'queue' => @queue)
  end

  def total(batch)
    Wurk::Batch::Status.new(batch.bid).total
  end

  def ttl_after_success(batch)
    batch.jobs { perform_one }
    ack_success(batch.bid, jid_for(@queue, batch.bid))
    @pool.with { |c| c.call('TTL', "b-#{batch.bid}") }
  end

  def ack_success(bid, jid)
    mw = Wurk::Batch::ServerMiddleware.new
    mw.config = Wurk.configuration
    mw.call(nil, { 'bid' => bid, 'jid' => jid }, @queue) {} # rubocop:disable Lint/EmptyBlock
  end

  def kill(bid, jid)
    Wurk::Batch::DeathHandler.call({ 'bid' => bid, 'jid' => jid }, RuntimeError.new('boom'))
  end

  def queued(queue)
    @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, -1) }.map { |s| JSON.parse(s) }
  end

  def jid_for(queue, bid)
    queued(queue).find { |j| j['bid'] == bid }.fetch('jid')
  end

  def jids_for(queue, bid)
    queued(queue).select { |j| j['bid'] == bid }.map { |j| j['jid'] }
  end

  def callbacks_fired(event:, bid:)
    queued(@cbq).count do |j|
      j['class'] == 'Wurk::Batch::CallbackJob' && j['args'][0] == bid && j['args'][2] == event
    end
  end

  def assert_dead(*bids)
    dead = @pool.with { |c| c.call('ZRANGE', 'dead-batches', 0, -1) }

    bids.each { |bid| assert_includes dead, bid }
  end

  # Minitest 6 dropped #stub, so swap Wurk::Client.push for the duration of
  # the block and restore it. Safe under the suite's fork-based parallelism.
  # $VERBOSE is toggled off to mute the method-redefinition warning.
  def with_push_override(replacement)
    original = Wurk::Client.singleton_method(:push)
    redefine_push(replacement)
    yield
  ensure
    redefine_push(original)
  end

  def redefine_push(impl)
    verbose = $VERBOSE
    $VERBOSE = nil
    Wurk::Client.singleton_class.send(:define_method, :push, impl)
  ensure
    $VERBOSE = verbose
  end
end
