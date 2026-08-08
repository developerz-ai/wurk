# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'stringio'

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

  # Guards the one test that swaps the process-global `Wurk.logger` (there is
  # no thread-local override point) so it can't race another thread's test
  # method within this same parallelized class.
  LOGGER_MUTEX = Mutex.new

  def setup
    super
    @pool       = Wurk.configuration.redis_pool
    @class_name = "BatchLifeJob@#{Process.pid}-#{object_id}"
    @queue      = "blq-#{Process.pid}-#{object_id}"
    @cbq        = "blcb-#{Process.pid}-#{object_id}"
    @morgue     = "bldead-#{Process.pid}-#{object_id}"
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
      conn.call('DEL', @morgue)
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
    batch.jobs {}

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

  # The duration statsd metric is best-effort: it runs ahead of the enqueue on
  # the acking job's thread, and that ack already removed the jid, so a raise
  # there would abort fire_success with nothing left to re-drive it — the
  # success callbacks + linger would be stranded for good.
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

  # #18: a Limiter reschedule inside a batch is *neither* success nor failure.
  # The Limiter middleware (INNER of Batch) re-enqueues the job and raises
  # Limiter::Rescheduled (a JobRetry::Skip); the Batch middleware must skip
  # both acks — pending stays put, no failure recorded, no :success. :success
  # fires only once the rescheduled job later runs to success.
  def test_limiter_reschedule_inside_batch_is_neither_success_nor_failure
    batch = new_batch(success: 'S')
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)

    mw = build_server_middleware
    assert_raises(Wurk::Limiter::Rescheduled) do
      mw.call(nil, { 'bid' => batch.bid, 'jid' => jid }, @queue) { raise Wurk::Limiter::Rescheduled }
    end

    status = Wurk::Batch::Status.new(batch.bid)

    assert_equal 1, status.pending, 'a rescheduled job must not ack success'
    assert_equal 0, status.failures, 'a rescheduled job must not ack failure'
    assert_equal 0, callbacks_fired(event: 'success', bid: batch.bid), ':success must not fire on reschedule'

    ack_success(batch.bid, jid) # the rescheduled job later runs to success

    assert_equal 0, Wurk::Batch::Status.new(batch.bid).pending
    assert_equal 1, callbacks_fired(event: 'success', bid: batch.bid)
  end

  # --- #212: dead job manually retried to success ------------------------

  # Spec §2.4: ":success never fires unless the dead job is manually retried
  # to success." Full morgue round-trip: the job dies into the dead set, the
  # operator hits "retry" (SortedEntry#retry → Client push → BATCH_PUSH), the
  # retry succeeds, and the batch fires :success.
  def test_dead_job_retried_from_morgue_to_success_fires_success
    batch = new_batch(success: 'S', complete: 'C', death: 'D')
    batch.jobs { perform_one }
    payload = queued(@queue).find { |j| j['bid'] == batch.bid }
    jid = payload.fetch('jid')

    morgue = Wurk::DeadSet.new(@morgue)
    morgue.kill(JSON.dump(payload))

    assert_equal 1, callbacks_fired(event: 'death', bid: batch.bid)
    assert_equal 0, callbacks_fired(event: 'success', bid: batch.bid)

    morgue.find_job(jid).retry
    status = Wurk::Batch::Status.new(batch.bid)

    assert_equal 1, status.total, 'manual retry must not recount total'
    assert_equal 1, status.pending, 'manual retry must not recount pending'
    assert_empty status.dead_jids
    assert_nil(@pool.with { |c| c.call('ZSCORE', 'dead-batches', batch.bid) },
               'recovered batch must leave dead-batches')

    ack_success(batch.bid, jid)

    assert_equal 1, callbacks_fired(event: 'success', bid: batch.bid)
    assert_equal 1, callbacks_fired(event: 'death', bid: batch.bid), ':death must not re-fire'
    assert_equal 0, Wurk::Batch::Status.new(batch.bid).pending
  end

  # With two dead jobs, retrying only one must keep :success suppressed —
  # the death mark clears only when the died set fully drains.
  def test_success_stays_suppressed_while_another_dead_jid_remains
    batch = new_batch(success: 'S', death: 'D')
    batch.jobs { 2.times { perform_one } }
    jid_a, jid_b = jids_for(@queue, batch.bid)
    kill(batch.bid, jid_a)
    kill(batch.bid, jid_b)

    retry_dead_job(batch.bid, jid_a)
    ack_success(batch.bid, jid_a)

    assert_equal 0, callbacks_fired(event: 'success', bid: batch.bid)
    assert_equal('1', @pool.with { |c| c.call('HGET', "b-#{batch.bid}", 'death') })
    refute_nil(@pool.with { |c| c.call('ZSCORE', 'dead-batches', batch.bid) })
  end

  # A retried dead job that dies again re-marks the batch dead (durable flag
  # + dead-batches) without re-enqueuing :death; a second retry that finally
  # succeeds still fires :success.
  def test_re_death_after_recovery_re_marks_dead_without_refiring_death
    batch = new_batch(success: 'S', death: 'D')
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)
    kill(batch.bid, jid)

    retry_dead_job(batch.bid, jid)
    kill(batch.bid, jid)

    assert_equal 1, callbacks_fired(event: 'death', bid: batch.bid), ':death enqueues at most once'
    assert_equal('1', @pool.with { |c| c.call('HGET', "b-#{batch.bid}", 'death') },
                 're-death must restore the durable death mark')
    refute_nil(@pool.with { |c| c.call('ZSCORE', 'dead-batches', batch.bid) },
               're-death must restore dead-batches membership')
    assert_equal 0, callbacks_fired(event: 'success', bid: batch.bid)

    retry_dead_job(batch.bid, jid)
    ack_success(batch.bid, jid)

    assert_equal 1, callbacks_fired(event: 'success', bid: batch.bid)
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

  # --- #226: descendant dead job retried to success lifts ancestor suppression

  # Spec §2.4 across the parent chain: a child's job dies (cascading :death up
  # to the parent), the operator retries it to success, the child fires
  # :success, and the parent fires :success once its own work is done too.
  def test_nested_descendant_recovery_fires_ancestor_success
    parent, child = nested(parent_cbs: { success: 'ParentSuccess', death: 'ParentDeath' },
                           child_cbs: { success: 'ChildSuccess', death: 'ChildDeath' })
    child_jid = jid_for(@queue, child.bid)
    kill(child.bid, child_jid)

    assert_equal 1, callbacks_fired(event: 'death', bid: parent.bid), 'child death cascades :death to the parent'
    assert_dead parent.bid, child.bid

    retry_dead_job(child.bid, child_jid)
    ack_success(child.bid, child_jid)

    assert_equal 1, callbacks_fired(event: 'success', bid: child.bid)
    assert_equal 0, callbacks_fired(event: 'success', bid: parent.bid),
                 'parent :success still waits on its own pending job'

    ack_success(parent.bid, jid_for(@queue, parent.bid))

    assert_equal 1, callbacks_fired(event: 'success', bid: parent.bid),
                 'parent :success fires once the recovered subtree and its own work are done'
    assert_equal 1, callbacks_fired(event: 'death', bid: parent.bid), 'parent :death must not re-fire'
    assert_nil(@pool.with { |c| c.call('ZSCORE', 'dead-batches', parent.bid) }, 'recovered parent leaves dead-batches')
  end

  # A parent with two dead children must keep :success suppressed until BOTH
  # recover — recovering only one leaves the parent's subtree still dead.
  def test_ancestor_stays_suppressed_while_other_descendant_dead
    parent = new_batch(success: 'ParentSuccess', death: 'ParentDeath')
    child_a = child_b = nil
    parent.jobs do
      perform_one # parent's own job — without it the parent gets an Empty marker
      child_a = new_batch
      child_a.jobs { perform_one }
      child_b = new_batch
      child_b.jobs { perform_one }
    end
    parent_jid = jid_for(@queue, parent.bid)
    a_jid = jid_for(@queue, child_a.bid)
    b_jid = jid_for(@queue, child_b.bid)
    kill(child_a.bid, a_jid)
    kill(child_b.bid, b_jid)

    assert_equal 1, callbacks_fired(event: 'death', bid: parent.bid)

    retry_dead_job(child_a.bid, a_jid)
    ack_success(child_a.bid, a_jid)
    ack_success(parent.bid, parent_jid)

    assert_equal 0, callbacks_fired(event: 'success', bid: parent.bid),
                 'parent stays suppressed while child_b is still dead'
    assert_equal('1', @pool.with { |c| c.call('HGET', "b-#{parent.bid}", 'death') },
                 'parent keeps its death mark while a descendant is dead')

    retry_dead_job(child_b.bid, b_jid)
    ack_success(child_b.bid, b_jid)

    assert_equal 1, callbacks_fired(event: 'success', bid: parent.bid),
                 'parent :success fires once every descendant has recovered'
    assert_equal 1, callbacks_fired(event: 'death', bid: parent.bid)
  end

  # The clear walks the full chain: a leaf recovery must lift suppression on
  # every ancestor up to the root.
  def test_deep_recovery_fires_success_through_every_ancestor
    grand = new_batch(success: 'GrandSuccess', death: 'GrandDeath')
    parent = child = nil
    grand.jobs do
      perform_one
      parent = new_batch(success: 'ParentSuccess')
      parent.jobs do
        perform_one
        child = new_batch(success: 'ChildSuccess')
        child.jobs { perform_one }
      end
    end
    child_jid = jid_for(@queue, child.bid)
    kill(child.bid, child_jid)

    assert_equal 1, callbacks_fired(event: 'death', bid: grand.bid), 'death cascades to the root'

    retry_dead_job(child.bid, child_jid)
    ack_success(child.bid, child_jid)
    ack_success(parent.bid, jid_for(@queue, parent.bid))
    ack_success(grand.bid, jid_for(@queue, grand.bid))

    assert_equal 1, callbacks_fired(event: 'success', bid: child.bid)
    assert_equal 1, callbacks_fired(event: 'success', bid: parent.bid)
    assert_equal 1, callbacks_fired(event: 'success', bid: grand.bid),
                 'leaf recovery lifts suppression all the way to the root'
    assert_nil(@pool.with { |c| c.call('ZSCORE', 'dead-batches', grand.bid) })
  end

  # A descendant that dies again after recovery must re-mark every ancestor
  # dead (durable flag + dead-batches) without re-enqueuing :death anywhere.
  def test_descendant_re_death_re_marks_ancestors_without_refiring_death
    parent, child = nested(parent_cbs: { success: 'ParentSuccess', death: 'ParentDeath' },
                           child_cbs: { death: 'ChildDeath' })
    child_jid = jid_for(@queue, child.bid)

    kill(child.bid, child_jid)
    retry_dead_job(child.bid, child_jid)
    kill(child.bid, child_jid)

    assert_equal 1, callbacks_fired(event: 'death', bid: child.bid), 'child :death enqueues at most once'
    assert_equal 1, callbacks_fired(event: 'death', bid: parent.bid), 'parent :death enqueues at most once'
    assert_equal('1', @pool.with { |c| c.call('HGET', "b-#{parent.bid}", 'death') },
                 're-death restores the parent death mark')
    refute_nil(@pool.with { |c| c.call('ZSCORE', 'dead-batches', parent.bid) },
               're-death restores parent dead-batches membership')

    retry_dead_job(child.bid, child_jid)
    ack_success(child.bid, child_jid)
    ack_success(parent.bid, jid_for(@queue, parent.bid))

    assert_equal 1, callbacks_fired(event: 'success', bid: parent.bid),
                 'a second recovery still fires parent :success'
  end

  # Retry window race (raised in PR #227 review): after a child's dead job has
  # been retried (BATCH_PUSH cleared the *child's* death mark and re-added the
  # jid to child.live) but BEFORE the worker actually runs it, the parent's
  # own job acks. The original death cascade already SREM'd the child from the
  # parent's pkids set and BATCH_PUSH doesn't re-add it — so kids_finished?
  # is true. But the parent's own cascaded death mark is untouched (BATCH_PUSH
  # operates on the child bid only; clear_death_on_recovery only runs from a
  # *successful* child drain via propagate_to_parent), so subtree_dead? is
  # still true and :success must stay suppressed until the retried job
  # actually succeeds.
  def test_parent_own_ack_in_retry_window_keeps_success_suppressed
    parent, child = nested(parent_cbs: { success: 'ParentSuccess', death: 'ParentDeath' },
                           child_cbs: { success: 'ChildSuccess' })
    parent_jid = jid_for(@queue, parent.bid)
    child_jid  = jid_for(@queue, child.bid)
    kill(child.bid, child_jid)
    retry_dead_job(child.bid, child_jid)

    assert_nil(@pool.with { |c| c.call('HGET', "b-#{child.bid}", 'death') },
               'BATCH_PUSH cleared the child mark — retry window has opened')
    assert_equal('1', @pool.with { |c| c.call('HGET', "b-#{parent.bid}", 'death') },
                 'BATCH_PUSH must not touch the parent — its cascaded mark stays set')

    ack_success(parent.bid, parent_jid)

    assert_equal 0, callbacks_fired(event: 'success', bid: parent.bid),
                 ':success must not fire before the retried descendant job has actually succeeded'

    ack_success(child.bid, child_jid)

    assert_equal 1, callbacks_fired(event: 'success', bid: child.bid)
    assert_equal 1, callbacks_fired(event: 'success', bid: parent.bid),
                 ':success fires once the retried job acks and lifts the parent mark via propagate_to_parent'
    assert_equal 1, callbacks_fired(event: 'death', bid: parent.bid), 'parent :death must not re-fire'
  end

  # Mixed shape: a batch with BOTH its own dead job and a dead child. Retrying
  # only its own job (which drains its own died set and clears its own mark via
  # BATCH_PUSH) must not let :success fire while the child subtree is still
  # dead — subtree_dead? catches the still-dead child.
  def test_own_recovery_stays_suppressed_while_child_subtree_dead
    parent, child = nested(parent_cbs: { success: 'ParentSuccess', death: 'ParentDeath' })
    parent_jid = jid_for(@queue, parent.bid)
    child_jid  = jid_for(@queue, child.bid)
    kill(child.bid, child_jid)
    kill(parent.bid, parent_jid)

    retry_dead_job(parent.bid, parent_jid)
    ack_success(parent.bid, parent_jid)

    assert_equal 0, callbacks_fired(event: 'success', bid: parent.bid),
                 "parent's own recovery must not fire :success while the child is dead"

    retry_dead_job(child.bid, child_jid)
    ack_success(child.bid, child_jid)

    assert_equal 1, callbacks_fired(event: 'success', bid: parent.bid),
                 'parent :success fires once the child subtree also recovers'
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

  # --- F16: the dedup marker is written after the enqueue, not before -----

  # Regression guard for the loss window: with the marker claimed first, a
  # crash between the SET and the push loses the callback for good (nothing
  # re-drives maybe_fire once the ack SREM'd the jid). The marker must not
  # exist yet at the moment Wurk::Client.push runs.
  def test_complete_callback_is_enqueued_before_its_dedup_marker
    batch = new_batch(complete: 'C')
    batch.jobs { perform_one }

    assert_equal 0, marker_state_at_push(batch.bid, 'complete') { ack_success(batch.bid, jid_for(@queue, batch.bid)) }
    assert_equal 1, exists("b-#{batch.bid}-complete"), 'marker must be written once the enqueue pass completes'
  end

  def test_success_callback_is_enqueued_before_its_dedup_marker
    batch = new_batch(success: 'S')
    batch.jobs { perform_one }

    assert_equal 0, marker_state_at_push(batch.bid, 'success') { ack_success(batch.bid, jid_for(@queue, batch.bid)) }
    assert_equal 1, exists("b-#{batch.bid}-success"), 'marker must be written once the enqueue pass completes'
  end

  # `:death` deliberately keeps claim-before-enqueue — its durable mark and
  # `dead-batches` membership are persisted before the guard, so the crash
  # window costs the notification, not the batch's death state. Pinned so a
  # consistency-driven reorder has to argue with this test first.
  def test_death_callback_keeps_its_claim_before_the_enqueue
    batch = new_batch(death: 'D')
    batch.jobs { perform_one }

    assert_equal 1, marker_state_at_push(batch.bid, 'death') { kill(batch.bid, jid_for(@queue, batch.bid)) }
  end

  # The crash the reorder closes: process dies between the push and the mark.
  # The callback is already durably queued, and the batch is left re-fireable
  # rather than silently stranded.
  def test_crash_between_enqueue_and_marker_leaves_the_callback_queued
    batch = new_batch(complete: 'C')
    batch.jobs { perform_one }

    assert_raises(RuntimeError) do
      with_failing_dedup_set(batch.bid) { Wurk::Batch::Callbacks.fire_complete(batch.bid) }
    end

    assert_equal 1, callbacks_fired(event: 'complete', bid: batch.bid),
                 'the callback must already be enqueued when the marker write dies'
    assert_equal 0, exists("b-#{batch.bid}-complete")
  end

  # The accepted direction: the re-drive after such a crash duplicates rather
  # than loses. Callback jobs retry anyway and must be idempotent (spec §12).
  def test_redrive_after_a_lost_marker_duplicates_rather_than_loses
    batch = new_batch(complete: 'C')
    batch.jobs { perform_one }

    assert_raises(RuntimeError) do
      with_failing_dedup_set(batch.bid) { Wurk::Batch::Callbacks.fire_complete(batch.bid) }
    end
    Wurk::Batch::Callbacks.fire_complete(batch.bid)

    assert_equal 2, callbacks_fired(event: 'complete', bid: batch.bid)
  end

  # A reclaimed child re-running propagate_to_parent re-enters the parent's
  # maybe_fire with its counts still at zero — the marker read must absorb it.
  def test_reclaimed_child_repropagating_does_not_refire_parent_callbacks
    parent, child = nested_fully_acked(success: 'ParentSuccess', complete: 'ParentComplete')

    Wurk::Batch::Callbacks.propagate_to_parent(child.bid)

    assert_equal 1, callbacks_fired(event: 'complete', bid: parent.bid)
    assert_equal 1, callbacks_fired(event: 'success', bid: parent.bid)
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

  def test_parent_callbacks_wait_when_parent_acks_before_child
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

  # Reopening a batch inside every job to register its callback is a common
  # shape; without dedup that persists one entry per job and fires the
  # callback that many times.
  def test_reopening_to_register_an_identical_callback_persists_one_entry
    batch = new_batch
    batch.jobs { perform_one }
    bid = batch.bid
    100.times { Wurk::Batch.new(bid).on(:success, 'RepeatSuccess') }

    ack_success(bid, jid_for(@queue, bid))

    assert_equal 1, persisted_callbacks(bid).size
    assert_equal 1, callbacks_fired(event: 'success', bid: bid)
  end

  # Dedup keys on the whole triple: same target, different options stays two
  # registrations and fires twice.
  def test_reopening_with_different_callback_options_keeps_both
    batch = new_batch
    batch.jobs { perform_one }
    Wurk::Batch.new(batch.bid).on(:success, 'ShardSuccess', 'shard' => 1)
    Wurk::Batch.new(batch.bid).on(:success, 'ShardSuccess', 'shard' => 2)

    ack_success(batch.bid, jid_for(@queue, batch.bid))

    assert_equal 2, callbacks_fired(event: 'success', bid: batch.bid)
  end

  def test_on_past_the_callback_cap_is_dropped
    batch = new_batch
    batch.jobs { perform_one }
    fill_callbacks(batch.bid)

    batch.on(:success, 'Overflow')

    assert_equal Wurk::Batch::CALLBACKS_MAX, persisted_callbacks(batch.bid).size
    refute_includes persisted_callbacks(batch.bid).map { |c| c[1] }, 'Overflow'
  end

  def test_on_past_the_callback_cap_logs_the_drop
    batch = new_batch
    batch.jobs { perform_one }
    fill_callbacks(batch.bid)

    log = capture_log { batch.on(:success, 'Overflow') }

    assert_match(/#{Wurk::Batch::CALLBACKS_MAX} callback limit reached/, log)
  end

  # Pre-flush registrations never reach BATCH_APPEND_CALLBACK — they stage in
  # memory and land in one HSET — so the dedup and the cap have to hold on
  # that path too, or the first write already violates the contract.
  def test_duplicate_callback_before_flush_persists_one_entry
    batch = new_batch
    100.times { batch.on(:success, 'RepeatSuccess') }

    batch.jobs { perform_one }
    ack_success(batch.bid, jid_for(@queue, batch.bid))

    assert_equal 1, persisted_callbacks(batch.bid).size
    assert_equal 1, callbacks_fired(event: 'success', bid: batch.bid)
  end

  # Options are compared as persisted: symbol and string keys serialise to the
  # same entry, so registering both must not double-fire.
  def test_duplicate_callback_before_flush_ignores_option_key_type
    batch = new_batch
    batch.on(:success, 'NormalizedSuccess', shard: 1)
    batch.on(:success, 'NormalizedSuccess', 'shard' => 1)

    batch.jobs { perform_one }

    assert_equal 1, persisted_callbacks(batch.bid).size
  end

  def test_distinct_callback_options_before_flush_keep_both
    batch = new_batch
    batch.on(:success, 'ShardSuccess', 'shard' => 1)
    batch.on(:success, 'ShardSuccess', 'shard' => 2)

    batch.jobs { perform_one }
    ack_success(batch.bid, jid_for(@queue, batch.bid))

    assert_equal 2, callbacks_fired(event: 'success', bid: batch.bid)
  end

  def test_on_before_flush_past_the_callback_cap_is_dropped
    batch = new_batch
    fill_staged_callbacks(batch)

    batch.on(:success, 'Overflow')
    batch.jobs { perform_one }

    assert_equal Wurk::Batch::CALLBACKS_MAX, persisted_callbacks(batch.bid).size
    refute_includes persisted_callbacks(batch.bid).map { |c| c[1] }, 'Overflow'
  end

  def test_on_before_flush_past_the_callback_cap_logs_the_drop
    batch = new_batch
    fill_staged_callbacks(batch)

    log = capture_log { batch.on(:success, 'Overflow') }

    assert_match(/#{Wurk::Batch::CALLBACKS_MAX} callback limit reached/, log)
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

  # Parent + child both acked to success, i.e. the parent's callbacks have
  # already fired through the child's propagate_to_parent.
  def nested_fully_acked(**parent_cbs)
    parent, child = nested(parent_cbs: parent_cbs)
    ack_success(parent.bid, jid_for(@queue, parent.bid))
    ack_success(child.bid, jid_for(@queue, child.bid))
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
    mw.call(nil, { 'bid' => bid, 'jid' => jid }, @queue) {}
  end

  def kill(bid, jid)
    Wurk::Batch::DeathHandler.call({ 'bid' => bid, 'jid' => jid }, RuntimeError.new('boom'))
  end

  # The morgue "retry" path without the morgue: re-push the dead job's
  # payload through Wurk::Client, exactly what SortedEntry#retry does after
  # removing the entry from the dead zset.
  def retry_dead_job(bid, jid)
    Wurk::Client.push('class' => @class_name, 'args' => [], 'queue' => @queue, 'bid' => bid, 'jid' => jid)
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

  def persisted_callbacks(bid)
    JSON.parse(@pool.with { |c| c.call('HGET', "b-#{bid}", 'callbacks') })
  end

  # Saturate the in-memory staging array — the pre-flush twin of
  # `fill_callbacks`, which saturates the persisted one.
  def fill_staged_callbacks(batch)
    Wurk::Batch::CALLBACKS_MAX.times { |i| batch.on(:success, "Filler#{i}") }
  end

  # Saturate the callback array without paying CALLBACKS_MAX round trips.
  def fill_callbacks(bid)
    full = Array.new(Wurk::Batch::CALLBACKS_MAX) { |i| ['success', "Filler#{i}", {}] }
    @pool.with { |c| c.call('HSET', "b-#{bid}", 'callbacks', JSON.generate(full)) }
  end

  def callbacks_fired(event:, bid:)
    queued(@cbq).count do |j|
      j['class'] == 'Wurk::Batch::CallbackJob' && j['args'][0] == bid && j['args'][2] == event
    end
  end

  # Swap in a StringIO logger for the duration of the block and return
  # what it captured — used to assert the cap/duplicate-registration
  # warnings without disturbing the global IO::NULL logger other tests rely on.
  def capture_log
    LOGGER_MUTEX.synchronize do
      io = StringIO.new
      previous = Wurk.logger
      Wurk.logger = Logger.new(io)
      begin
        yield
        io.string
      ensure
        Wurk.logger = previous
      end
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

  # EXISTS b-<bid>-<event> sampled from inside Wurk::Client.push, i.e. exactly
  # when a callback job is being enqueued — 0 means the marker is written after
  # the enqueue (F16), 1 means it was claimed before. Every other push is
  # delegated untouched so a concurrent test in this process is unaffected.
  # The override runs with `self` rebound to Wurk::Client (define_method), so
  # everything it needs is captured as a closure local — no test helpers.
  def marker_state_at_push(bid, event, &)
    observed = nil
    pool     = @pool
    key      = "b-#{bid}-#{event}"
    ours     = callback_matcher(bid, event)
    original = Wurk::Client.singleton_method(:push)
    sampling = lambda do |item|
      observed = pool.with { |c| c.call('EXISTS', key) }.to_i if ours.call(item)
      original.call(item)
    end
    with_push_override(sampling, &)
    observed
  end

  def callback_matcher(bid, event)
    lambda do |item|
      item['class'] == 'Wurk::Batch::CallbackJob' && Array(item['args']).values_at(0, 2) == [bid, event]
    end
  end

  # Simulates the process dying between the callback enqueue and the dedup
  # marker write. Scoped to one bid so concurrently running tests in this
  # process keep the real implementation.
  def with_failing_dedup_set(bid)
    original = Wurk::Batch::Callbacks.method(:dedup_set)
    crashing = lambda do |b, event|
      raise 'crash' if b == bid

      original.call(b, event)
    end
    redefine_dedup_set(crashing)
    yield
  ensure
    redefine_dedup_set(->(b, event) { original.call(b, event) })
  end

  def redefine_dedup_set(impl)
    verbose = $VERBOSE
    $VERBOSE = nil
    Wurk::Batch::Callbacks.singleton_class.send(:define_method, :dedup_set, impl)
  ensure
    $VERBOSE = verbose
  end

  def exists(key)
    @pool.with { |c| c.call('EXISTS', key) }.to_i
  end
end
