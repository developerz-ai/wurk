# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'monitor'

# The durable half of the batch fire gate: every drain-observing script records
# the bid in Keys::BATCH_FIRES in the same atomic step, and Batch::FireRecovery
# re-drives entries whose fire was lost (a caller that died mid-fire, or an
# outage that ate every in-process retrying attempt). Real Redis; callbacks are
# asserted by inspecting the callback queue rather than by running them.
class BatchFireRecoveryTest < Wurk::Test::UnitCase
  parallelize_me!

  # Serializes the tests that touch process-global state (singleton-method
  # stubs) against the rest of this class's threads. Reentrant.
  GLOBAL_LOCK = Monitor.new

  def setup
    super
    @pool       = Wurk.configuration.redis_pool
    @class_name = "BatchFireRecoveryJob@#{Process.pid}-#{object_id}"
    @queue      = "bfq-#{Process.pid}-#{object_id}"
    @cbq        = "bfcb-#{Process.pid}-#{object_id}"
    @bids       = []
    @lock_keys  = []
  end

  def teardown
    @pool.with do |conn|
      @bids.uniq.each do |bid|
        conn.call('UNLINK', *Wurk::Batch.keys_for(bid))
        conn.call('ZREM', 'batches', bid)
        conn.call('ZREM', 'dead-batches', bid)
        conn.call('ZREM', Wurk::Keys::BATCH_FIRES, bid)
      end
      @lock_keys.each { |key| conn.call('DEL', key) }
      [@queue, @cbq].each do |q|
        conn.call('DEL', "queue:#{q}")
        conn.call('SREM', 'queues', q)
      end
    end
  ensure
    super
  end

  # --- the drain writes the index ----------------------------------------

  # The ack observes the drain and records the bid atomically — here the
  # caller "died" between the ack and the fire, which is exactly the state
  # FireRecovery exists for: entry present, callbacks not fired.
  def test_drain_records_the_bid_in_the_fire_index
    batch = new_batch(complete: 'C', success: 'S')
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)
    @pool.with { |c| Wurk::Batch.ack_success(c, batch.bid, jid) }

    assert_operator fire_score(batch.bid), :>, 0, 'the drain wrote the bid into the fire index'
    assert_equal 0, callbacks_fired(batch.bid, 'complete')
    assert_equal 0, callbacks_fired(batch.bid, 'success')
  end

  # A successful fire pass clears the entry: the drain is durable in the
  # markers, so nothing is owed anymore.
  def test_successful_fire_clears_the_entry
    batch = new_batch(complete: 'C')
    batch.jobs { perform_one }
    middleware.call(nil, { 'bid' => batch.bid, 'jid' => jid_for(@queue, batch.bid) }, @queue) {}

    assert_equal 1, callbacks_fired(batch.bid, 'complete')
    assert_nil fire_score(batch.bid), 'the entry was cleared once the fire completed'
  end

  # The parent-drain-via-kid_done case batch_ack_success never sees: the
  # parent's own jobs are acked, its last child drains, and the parent's bid
  # is what lands in the index.
  def test_child_drain_records_the_parent_in_the_fire_index
    parent, child = nested(parent_cbs: { complete: 'PC' })
    ack_success(parent.bid, jid_for(@queue, parent.bid))
    assert_nil fire_score(parent.bid), 'parent still has a pending child: not drained'

    # The parent's fire raises inside the child's fire pass, and ServerMiddleware
    # reports a fire failure to the error handlers instead of propagating (an
    # exception here would send the child's job to retry after it succeeded).
    # So the observable is the report plus the surviving index entry.
    reported = []
    with_stub(Wurk::Batch::Callbacks, :maybe_fire, lambda { |orig, bid, **kw|
      bid == parent.bid ? raise('blip') : orig.call(bid, **kw)
    }) do
      with_error_handler(->(ex, _ctx, _cfg) { reported << ex }) do
        ack_success(child.bid, jid_for(@queue, child.bid))
      end
    end
    assert(reported.any? { |ex| ex.message == 'blip' }, 'the lost parent fire is reported')

    assert_operator fire_score(parent.bid), :>, 0, 'kid_done recorded the parent for recovery'
    assert_equal 0, callbacks_fired(parent.bid, 'complete')

    backdate(parent.bid)
    recovery.sweep

    assert_equal 1, callbacks_fired(parent.bid, 'complete')
    assert_nil fire_score(parent.bid)
  end

  # The death path records the bid the same way; recovery re-drives the
  # :complete it lost, while the claim-first :death is never duplicated.
  def test_death_ack_records_the_bid_and_recovery_never_duplicates_death
    batch = new_batch(complete: 'C', death: 'D')
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)

    with_stub(Wurk::Batch::Callbacks, :maybe_fire, lambda { |orig, bid, **kw|
      bid == batch.bid ? raise('blip') : orig.call(bid, **kw)
    }) do
      assert_raises(RuntimeError) { kill(batch.bid, jid) }
    end

    assert_operator fire_score(batch.bid), :>, 0, 'the death ack wrote the bid into the fire index'
    assert_equal 1, callbacks_fired(batch.bid, 'death'), ':death fired before the fire pass failed'
    assert_equal 0, callbacks_fired(batch.bid, 'complete')

    backdate(batch.bid)
    recovery.sweep

    assert_equal 1, callbacks_fired(batch.bid, 'complete')
    assert_equal 1, callbacks_fired(batch.bid, 'death'), ':death stays at-most-once'
    assert_nil fire_score(batch.bid)
  end

  # --- the sweep re-drives -----------------------------------------------

  def test_sweep_redrives_a_drained_but_unfired_bid_exactly_once
    batch = new_batch(complete: 'C', success: 'S')
    batch.jobs { perform_one }
    @pool.with { |c| Wurk::Batch.ack_success(c, batch.bid, jid_for(@queue, batch.bid)) }
    backdate(batch.bid)

    recovery.sweep

    assert_equal 1, callbacks_fired(batch.bid, 'complete')
    assert_equal 1, callbacks_fired(batch.bid, 'success')
    assert_nil fire_score(batch.bid), 'the recovered entry is cleared'

    recovery.sweep # a second sweep has nothing left to re-drive
    assert_equal 1, callbacks_fired(batch.bid, 'complete')
  end

  # An entry within the grace window is left to the caller's in-process
  # re-drive, which owns every fire that is merely slow.
  def test_sweep_leaves_entries_within_the_grace_alone
    batch = new_batch(complete: 'C')
    batch.jobs { perform_one }
    @pool.with { |c| Wurk::Batch.ack_success(c, batch.bid, jid_for(@queue, batch.bid)) }

    recovery.sweep

    assert_operator fire_score(batch.bid), :>, 0, 'within grace: not swept'
    assert_equal 0, callbacks_fired(batch.bid, 'complete')
  end

  # An entry whose batch is gone can never fire again: swept away, nothing
  # enqueued.
  def test_sweep_retires_an_entry_whose_batch_is_gone
    batch = new_batch
    batch.jobs { perform_one }
    Wurk::Batch::Status.new(batch.bid).delete
    backdate(batch.bid)

    recovery.sweep

    assert_nil fire_score(batch.bid), 'the stale entry was swept'
    assert_empty callback_jobs(batch.bid)
  end

  # A re-drive that raises keeps the entry — the fire is still owed, and the
  # next sweep re-drives it.
  def test_a_failed_redrive_keeps_the_entry
    batch = new_batch(complete: 'C')
    batch.jobs { perform_one }
    @pool.with { |c| Wurk::Batch.ack_success(c, batch.bid, jid_for(@queue, batch.bid)) }
    backdate(batch.bid)
    attempts = 0

    with_stub(Wurk::Batch::Callbacks, :maybe_fire, lambda { |orig, bid, **kw|
      if bid == batch.bid && attempts.zero?
        attempts += 1
        raise 'redis blip'
      end
      orig.call(bid, **kw)
    }) do
      with_error_handler(->(_ex, _ctx, _cfg) {}) { recovery.sweep }
    end

    assert_equal 1, attempts
    assert_operator fire_score(batch.bid), :>, 0, 'the failed re-drive kept its entry'
    assert_equal 0, callbacks_fired(batch.bid, 'complete')

    recovery.sweep

    assert_equal 1, callbacks_fired(batch.bid, 'complete')
    assert_nil fire_score(batch.bid)
  end

  # The markers dedup: an entry left behind for an already-fired drain (a
  # lost ZREM) re-drives to a no-op and is cleared, never re-enqueued.
  def test_redrive_of_an_already_fired_drain_enqueues_nothing
    batch = new_batch(complete: 'C', success: 'S')
    batch.jobs { perform_one }
    middleware.call(nil, { 'bid' => batch.bid, 'jid' => jid_for(@queue, batch.bid) }, @queue) {}
    backdate(batch.bid) # the fire's ZREM was lost to the same blip

    recovery.sweep

    assert_equal 1, callbacks_fired(batch.bid, 'complete')
    assert_equal 1, callbacks_fired(batch.bid, 'success')
    assert_nil fire_score(batch.bid)
  end

  # --- the cluster lock ---------------------------------------------------

  # A sibling holding the sweep lock means no sweep from this process: two
  # completions of one callback landing on either side of an outage are two
  # enqueues the markers cannot see, so the sweeps must not race.
  def test_tick_sweeps_only_when_it_wins_the_cluster_lock
    batch = new_batch(complete: 'C')
    batch.jobs { perform_one }
    @pool.with { |c| Wurk::Batch.ack_success(c, batch.bid, jid_for(@queue, batch.bid)) }
    backdate(batch.bid)
    lock_key = "batch:fires:lock-#{Process.pid}-#{object_id}"
    @lock_keys << lock_key
    locked = Wurk::Batch::FireRecovery.new(Wurk.configuration, lock_key: lock_key)

    @pool.with { |c| c.call('SET', lock_key, '1', 'NX', 'EX', 60) } # the sibling won it
    locked.tick
    assert_equal 0, callbacks_fired(batch.bid, 'complete'), 'a sibling holds the lock: no sweep'

    @pool.with { |c| c.call('DEL', lock_key) }
    locked.tick
    assert_equal 1, callbacks_fired(batch.bid, 'complete')
    assert_nil fire_score(batch.bid)
  end

  private

  def track(batch)
    @bids << batch.bid
    batch
  end

  def new_batch(**callbacks)
    batch = track(Wurk::Batch.new)
    batch.callback_queue = @cbq
    callbacks.each { |event, target| batch.on(event, target) }
    batch
  end

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

  def perform_one
    Wurk::Client.push('class' => @class_name, 'args' => [], 'queue' => @queue)
  end

  def middleware
    mw = Wurk::Batch::ServerMiddleware.new
    mw.config = Wurk.configuration
    mw
  end

  def ack_success(bid, jid)
    middleware.call(nil, { 'bid' => bid, 'jid' => jid }, @queue) {}
  end

  def kill(bid, jid)
    Wurk::Batch::DeathHandler.call({ 'bid' => bid, 'jid' => jid }, RuntimeError.new('boom'))
  end

  def recovery
    @recovery ||= Wurk::Batch::FireRecovery.new(Wurk.configuration)
  end

  # Moves the bid's entry past the grace window: models a fire lost some
  # thirty seconds ago, which is the only state a sweep is allowed to touch.
  def backdate(bid, seconds = Wurk::Batch::FireRecovery::GRACE + 1)
    @pool.with { |c| c.call('ZADD', Wurk::Keys::BATCH_FIRES, Wurk::Batch.drain_epoch - seconds, bid) }
  end

  def fire_score(bid)
    @pool.with { |c| c.call('ZSCORE', Wurk::Keys::BATCH_FIRES, bid) }
  end

  def queued(queue)
    @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, -1) }.map { |s| JSON.parse(s) }
  end

  def jid_for(queue, bid)
    queued(queue).find { |j| j['bid'] == bid }.fetch('jid')
  end

  def callback_jobs(bid)
    queued(@cbq).select { |j| j['class'] == 'Wurk::Batch::CallbackJob' && j['args'][0] == bid }
  end

  def callbacks_fired(bid, event)
    callback_jobs(bid).count { |j| j['args'][2] == event }
  end

  def with_error_handler(handler)
    GLOBAL_LOCK.synchronize do
      Wurk.configuration.error_handlers << handler
      begin
        yield
      ensure
        Wurk.configuration.error_handlers.delete(handler)
      end
    end
  end

  # Swaps a singleton method for `impl`, which receives the original method
  # first; restored afterwards. Implementations scope themselves to this
  # test's bid so concurrently running tests keep the real behaviour.
  def with_stub(target, name, impl)
    GLOBAL_LOCK.synchronize do
      original = target.method(name)
      redefine(target, name, ->(*args, **kw) { impl.call(original, *args, **kw) })
      begin
        yield
      ensure
        redefine(target, name, ->(*args, **kw) { original.call(*args, **kw) })
      end
    end
  end

  def redefine(target, name, impl)
    verbose = $VERBOSE
    $VERBOSE = nil
    target.singleton_class.send(:define_method, name, impl)
  ensure
    $VERBOSE = verbose
  end
end
