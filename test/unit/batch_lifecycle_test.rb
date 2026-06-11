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

  # The duration statsd metric is best-effort: fire_success has already burned
  # the `success` dedup key by the time it runs, so a raise there would strand
  # the success callbacks + linger with no retry to re-fire them.
  def test_success_callbacks_still_fire_when_duration_metric_raises
    batch = new_batch(success: 'S', complete: 'C')
    batch.jobs { perform_one }

    with_raising_distribution do
      ack_success(batch.bid, jid_for(@queue, batch.bid))
    end

    assert_equal 1, callbacks_fired(event: 'success', bid: batch.bid),
                 'success callback must enqueue even when the duration metric raises'
    refute_equal(-1, @pool.with { |c| c.call('TTL', "b-#{batch.bid}") },
                 'linger must still apply when the duration metric raises')
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

  # --- currently-failing tracking (#112) ---------------------------------

  # A job that raises (heading to retry) is recorded as currently-failing;
  # the count converges to 0 / [] once the retry succeeds.
  def test_failing_then_succeeding_job_converges_to_zero_failures
    batch = new_batch
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)

    fail_job(batch.bid, jid)
    status = Wurk::Batch::Status.new(batch.bid)

    assert_equal 1, status.failures
    assert_equal [jid], status.failed_jids

    ack_success(batch.bid, jid)
    status.reload!

    assert_equal 0, status.failures
    assert_empty status.failed_jids
  end

  # Re-failing the same jid across retries doesn't double-count.
  def test_repeated_failures_of_same_jid_count_once
    batch = new_batch
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)

    3.times { fail_job(batch.bid, jid) }

    assert_equal 1, Wurk::Batch::Status.new(batch.bid).failures
  end

  # A job that fails then exhausts retries leaves currently-failing (it's now
  # dead): failures returns to 0, jid moves from failed → died.
  def test_failing_then_dying_job_moves_to_died
    batch = new_batch(death: 'D')
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)

    fail_job(batch.bid, jid)
    kill(batch.bid, jid)
    status = Wurk::Batch::Status.new(batch.bid)

    assert_equal 0, status.failures
    assert_empty status.failed_jids
    assert_equal [jid], status.dead_jids
  end

  # Invalidation deletes the live jids set, so a failing job's short-circuited
  # success ack must still clear it from currently-failing (converge to 0).
  def test_invalidated_batch_with_failing_job_converges_failures
    batch = new_batch
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)

    fail_job(batch.bid, jid)
    assert_equal 1, Wurk::Batch::Status.new(batch.bid).failures

    batch.invalidate_all
    # Invalidated → ServerMiddleware short-circuits to ack_success.
    build_server_middleware.call(nil, { 'bid' => batch.bid, 'jid' => jid }, @queue) { :ok }
    status = Wurk::Batch::Status.new(batch.bid)

    assert_equal 0, status.failures
    assert_empty status.failed_jids
  end

  # A clean handled exit (JobRetry::Skip — e.g. expiry/interrupt) is not a
  # batch failure.
  def test_handled_skip_is_not_counted_as_failure
    batch = new_batch
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)

    mw = build_server_middleware
    assert_raises(Wurk::JobRetry::Skip) do
      mw.call(nil, { 'bid' => batch.bid, 'jid' => jid }, @queue) { raise Wurk::JobRetry::Skip }
    end

    assert_equal 0, Wurk::Batch::Status.new(batch.bid).failures
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

  # --- callback dedup (second fire is a no-op) ---------------------------

  def test_fire_complete_is_idempotent
    batch = new_batch(complete: 'C')
    batch.jobs { perform_one }

    Wurk::Batch::Callbacks.fire_complete(batch.bid)
    Wurk::Batch::Callbacks.fire_complete(batch.bid)

    assert_equal 1, callbacks_fired(event: 'complete', bid: batch.bid)
  end

  def test_fire_success_is_idempotent
    batch = new_batch(success: 'S')
    batch.jobs { perform_one }

    Wurk::Batch::Callbacks.fire_success(batch.bid)
    Wurk::Batch::Callbacks.fire_success(batch.bid)

    assert_equal 1, callbacks_fired(event: 'success', bid: batch.bid)
  end

  def test_fire_death_is_idempotent
    batch = new_batch(death: 'D')
    batch.jobs { perform_one }

    Wurk::Batch::Callbacks.fire_death(batch.bid)
    Wurk::Batch::Callbacks.fire_death(batch.bid)

    assert_equal 1, callbacks_fired(event: 'death', bid: batch.bid)
  end

  # --- callback_specs_for queue fallback ---------------------------------

  # callback_specs_for falls back to the 'default' queue when callback_queue is
  # blank (batch/callbacks.rb). Driven directly against a hand-written batch
  # hash rather than through fire_complete → Wurk::Client.push, which would
  # enqueue onto the process-global `queue:default` and race other classes
  # (the cross-class isolation issue tracked in #84).
  def test_callback_specs_fall_back_to_default_queue_when_blank
    batch = track(Wurk::Batch.new)
    @pool.with do |c|
      c.call('HSET', "b-#{batch.bid}", 'callbacks', JSON.dump([['complete', 'C', {}]]))
      c.call('HSET', "b-#{batch.bid}", 'callback_queue', '')
    end

    specs, queue = Wurk::Batch::Callbacks.send(:callback_specs_for, batch.bid)

    assert_equal 'default', queue, 'blank callback_queue must fall back to the default queue'
    assert_equal [['complete', 'C', {}]], specs
  end

  def test_callback_specs_keep_explicit_callback_queue
    batch = track(Wurk::Batch.new)
    @pool.with do |c|
      c.call('HSET', "b-#{batch.bid}", 'callbacks', JSON.dump([['complete', 'C', {}]]))
      c.call('HSET', "b-#{batch.bid}", 'callback_queue', @cbq)
    end

    _specs, queue = Wurk::Batch::Callbacks.send(:callback_specs_for, batch.bid)

    assert_equal @cbq, queue, 'a present callback_queue must be preserved'
  end

  # --- parse_callbacks empty ---------------------------------------------

  def test_fire_complete_with_no_registered_callbacks_enqueues_nothing
    batch = track(Wurk::Batch.new)
    batch.callback_queue = @cbq
    batch.jobs { perform_one }
    # No callbacks registered → persisted field is "[]"; force the
    # nil/empty branch of parse_callbacks by clearing it entirely.
    @pool.with { |c| c.call('HSET', "b-#{batch.bid}", 'callbacks', '') }

    Wurk::Batch::Callbacks.fire_complete(batch.bid)

    assert_equal 0, callbacks_fired(event: 'complete', bid: batch.bid)
  end

  # --- propagate_to_parent: undrained pkids ------------------------------

  def test_parent_success_waits_when_sibling_pkids_remain
    # Parent has two child batches; only one child succeeds, so the parent's
    # pkids set is not yet drained and parent :success must not fire.
    parent = new_batch(success: 'ParentSuccess')
    child_a = child_b = nil
    parent.jobs do
      child_a = new_batch
      child_a.jobs { perform_one }
      child_b = new_batch
      child_b.jobs { perform_one }
    end

    ack_success(child_a.bid, jid_for(@queue, child_a.bid))

    assert_equal 0, callbacks_fired(event: 'success', bid: parent.bid),
                 'parent :success must wait for all child batches'
    assert_equal(1, @pool.with { |c| c.call('SCARD', "b-#{parent.bid}-pkids") })
  end

  # --- #209: parent gated on running child batches ------------------------

  def test_parent_callbacks_wait_when_parent_acks_before_child # rubocop:disable Minitest/MultipleAssertions
    parent, child = nested(parent_cbs: { success: 'ParentSuccess', complete: 'ParentComplete' },
                           child_cbs: { success: 'ChildSuccess' })

    # The #209 race: the parent's own last job acks while the child batch
    # still has a pending job — nothing may fire on the parent yet.
    ack_success(parent.bid, jid_for(@queue, parent.bid))

    assert_equal 0, callbacks_fired(event: 'complete', bid: parent.bid),
                 'parent :complete must wait for running child batches'
    assert_equal 0, callbacks_fired(event: 'success', bid: parent.bid),
                 'parent :success must wait for running child batches'

    ack_success(child.bid, jid_for(@queue, child.bid))

    assert_equal 1, callbacks_fired(event: 'success', bid: child.bid)
    assert_equal 1, callbacks_fired(event: 'complete', bid: parent.bid)
    assert_equal 1, callbacks_fired(event: 'success', bid: parent.bid)
  end

  def test_parent_fires_when_child_acks_first_then_parent
    parent, child = nested(parent_cbs: { success: 'ParentSuccess', complete: 'ParentComplete' })
    ack_success(child.bid, jid_for(@queue, child.bid))

    assert_equal 0, callbacks_fired(event: 'success', bid: parent.bid),
                 'parent must still wait for its own job'

    ack_success(parent.bid, jid_for(@queue, parent.bid))

    assert_equal 1, callbacks_fired(event: 'complete', bid: parent.bid)
    assert_equal 1, callbacks_fired(event: 'success', bid: parent.bid)
  end

  def test_child_events_recorded_before_parent_under_parent_first_ack_order
    parent, child = nested(parent_cbs: { success: 'ParentSuccess' }, child_cbs: { success: 'ChildSuccess' })
    ack_success(parent.bid, jid_for(@queue, parent.bid))
    ack_success(child.bid, jid_for(@queue, child.bid))

    child_at  = @pool.with { |c| c.call('HGET', "b-#{child.bid}", 'success_at') }.to_f
    parent_at = @pool.with { |c| c.call('HGET', "b-#{parent.bid}", 'success_at') }.to_f

    assert_operator child_at, :<=, parent_at, 'child :success must precede parent :success (spec §2.4)'
  end

  def test_parent_complete_after_own_job_death_waits_for_running_child
    parent, child = nested(parent_cbs: { complete: 'ParentComplete', success: 'ParentSuccess' })
    kill(parent.bid, jid_for(@queue, parent.bid))

    assert_equal 0, callbacks_fired(event: 'complete', bid: parent.bid),
                 'parent :complete must wait for the running child even on the death path'

    ack_success(child.bid, jid_for(@queue, child.bid))

    assert_equal 1, callbacks_fired(event: 'complete', bid: parent.bid)
    assert_equal 0, callbacks_fired(event: 'success', bid: parent.bid),
                 'death must keep suppressing parent :success'
  end

  # --- #213: on() after first flush must persist --------------------------

  def test_on_after_jobs_flush_persists_and_fires
    batch = new_batch
    batch.jobs { perform_one }
    batch.on(:success, 'LateSuccess')

    ack_success(batch.bid, jid_for(@queue, batch.bid))

    assert_equal 1, callbacks_fired(event: 'success', bid: batch.bid),
                 'callback registered after the first flush must persist and fire (#213)'
  end

  def test_on_reopened_batch_persists_and_fires
    batch = new_batch
    batch.jobs { perform_one }

    Wurk::Batch.new(batch.bid).on(:complete, 'ReopenedComplete')
    ack_success(batch.bid, jid_for(@queue, batch.bid))

    assert_equal 1, callbacks_fired(event: 'complete', bid: batch.bid),
                 'callback registered on a reopened batch must persist and fire (#213)'
  end

  def test_on_after_flush_preserves_earlier_callbacks
    batch = new_batch(success: 'EarlySuccess')
    batch.jobs { perform_one }
    batch.on(:success, 'LateSuccess')

    ack_success(batch.bid, jid_for(@queue, batch.bid))

    assert_equal 2, callbacks_fired(event: 'success', bid: batch.bid)
  end

  def test_concurrent_reopeners_do_not_lose_each_others_callbacks
    batch = new_batch
    batch.jobs { perform_one }
    # Both handles load the persisted spec list BEFORE either appends — a
    # client-side read-modify-write would lose the first registration here.
    reopen_a = Wurk::Batch.new(batch.bid)
    reopen_b = Wurk::Batch.new(batch.bid)
    reopen_a.on(:success, 'ReopenA')
    reopen_b.on(:success, 'ReopenB')

    ack_success(batch.bid, jid_for(@queue, batch.bid))

    assert_equal 2, callbacks_fired(event: 'success', bid: batch.bid)
  end

  def test_on_unknown_batch_raises
    ghost = Wurk::Batch.new('no-such-bid-213')

    err = assert_raises(ArgumentError) { ghost.on(:success, 'Nope') }

    assert_match(/no longer exists/, err.message)
  end

  def test_on_after_event_already_fired_does_not_enqueue_again
    batch = new_batch(success: 'EarlySuccess')
    batch.jobs { perform_one }
    ack_success(batch.bid, jid_for(@queue, batch.bid))

    batch.on(:success, 'TooLate')

    assert_equal 1, callbacks_fired(event: 'success', bid: batch.bid),
                 'registration after the event fired must not re-fire, only warn'
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

  def build_server_middleware
    mw = Wurk::Batch::ServerMiddleware.new
    mw.config = Wurk.configuration
    mw
  end

  # Runs the batch server middleware with a raising block — the same path a
  # job hitting an exception (and heading to retry) takes. Only the synthetic
  # 'boom' is swallowed; a real regression on the ack path still fails loudly.
  def fail_job(bid, jid)
    build_server_middleware.call(nil, { 'bid' => bid, 'jid' => jid }, @queue) { raise 'boom' }
  rescue RuntimeError => e
    raise unless e.message == 'boom'
  end

  def queued(queue)
    @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, -1) }.map { |s| JSON.parse(s) }
  end

  # Minitest 6 dropped minitest/mock; hand-rolled stub that makes the duration
  # metric emission blow up (the Redis-hiccup case the rescue guards against).
  def with_raising_distribution
    sc = Wurk::Metrics::Statsd.singleton_class
    original = Wurk::Metrics::Statsd.method(:distribution)
    sc.define_method(:distribution) { |*_args, **_kw| raise 'statsd down' }
    yield
  ensure
    sc.define_method(:distribution) { |*a, **k| original.call(*a, **k) }
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
