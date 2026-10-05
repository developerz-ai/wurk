# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'monitor'

# The batch fire gate and the paths that feed it (#547 batch cluster): the
# drain is read atomically with each removal, every removal path can drain a
# batch, and no failure on the way to a callback is allowed to lose it or to
# re-run a job that already succeeded. Real Redis; callbacks are asserted by
# inspecting the callback queue rather than by running them.
class BatchFireGateTest < Wurk::Test::UnitCase
  parallelize_me!

  # Serializes the tests that touch process-global state (error handlers,
  # singleton-method stubs) against the rest of this class's threads.
  # Reentrant: a stub can be installed inside an error-handler swap.
  GLOBAL_LOCK = Monitor.new

  def setup
    super
    @pool       = Wurk.configuration.redis_pool
    @class_name = "BatchGateJob@#{Process.pid}-#{object_id}"
    @queue      = "bgq-#{Process.pid}-#{object_id}"
    @cbq        = "bgcb-#{Process.pid}-#{object_id}"
    @bids       = []
    @tags       = []
  end

  def teardown
    @pool.with do |conn|
      @bids.uniq.each do |bid|
        conn.call('UNLINK', *Wurk::Batch.keys_for(bid))
        conn.call('ZREM', 'batches', bid)
        conn.call('ZREM', 'dead-batches', bid)
      end
      @tags.each { |t| conn.call('DEL', "tags:#{t}") }
      [@queue, @cbq].each do |q|
        conn.call('DEL', "queue:#{q}")
        conn.call('SREM', 'queues', q)
      end
    end
  ensure
    super
  end

  # --- E3: child callback jobs hold the parent ---------------------------

  def test_child_callback_jobs_ride_in_the_parent_batch
    parent, child = nested(child_cbs: { success: 'ChildSuccess', complete: 'ChildComplete' })
    ack_success(parent.bid, jid_for(@queue, parent.bid))
    ack_success(child.bid, jid_for(@queue, child.bid))

    child_cbs = callback_jobs(child.bid)

    assert_equal 2, child_cbs.size
    assert(child_cbs.all? { |j| j['bid'] == parent.bid }, 'child callback jobs carry the parent bid')
    assert_equal child_cbs.map { |j| j['jid'] }.sort, live_jids(parent).sort
  end

  def test_root_batch_callback_jobs_carry_no_bid
    batch = new_batch(success: 'S')
    batch.jobs { perform_one }
    ack_success(batch.bid, jid_for(@queue, batch.bid))

    refute callback_jobs(batch.bid).first.key?('bid')
  end

  # A :death callback is a notification fired while the child may still be
  # running; it must neither hold the parent open nor count against it.
  def test_child_death_callback_does_not_join_the_parent
    parent, child = nested(child_cbs: { death: 'ChildDeath' })
    kill(child.bid, jid_for(@queue, child.bid))

    refute callback_jobs(child.bid).first.key?('bid')
    assert_equal [jid_for(@queue, parent.bid)], live_jids(parent)
  end

  # A child callback that dies is a dead job of the parent: the parent still
  # completes, and its :success stays suppressed.
  def test_child_callback_death_completes_the_parent_without_success
    parent, child = nested(parent_cbs: { complete: 'PC', success: 'PS', death: 'PD' },
                           child_cbs: { success: 'ChildSuccess' })
    ack_success(parent.bid, jid_for(@queue, parent.bid))
    ack_success(child.bid, jid_for(@queue, child.bid))
    kill(parent.bid, callback_jobs(child.bid).first['jid'])

    assert_equal 1, callbacks_fired(parent.bid, 'complete')
    assert_equal 1, callbacks_fired(parent.bid, 'death')
    assert_equal 0, callbacks_fired(parent.bid, 'success')
  end

  # An invalidated parent short-circuits its own jobs, but a child's callback
  # riding in it is still the child's callback and must run.
  def test_callback_job_runs_inside_an_invalidated_parent
    parent, child = nested(child_cbs: { success: 'ChildSuccess' })
    ack_success(child.bid, jid_for(@queue, child.bid))
    parent.invalidate_all
    cb = callback_jobs(child.bid).first
    ran = false

    middleware.call(nil, cb, @cbq) { ran = true }

    assert ran, 'the callback job was skipped by its invalidated parent'
  end

  # --- E4: invalidated batches drain and fire ----------------------------

  def test_invalidated_batch_drains_and_fires_its_callbacks
    batch = new_batch(complete: 'C', success: 'S')
    batch.jobs { 2.times { perform_one } }
    batch.invalidate_all
    ran = 0

    jids_for(@queue, batch.bid).each do |jid|
      middleware.call(nil, { 'bid' => batch.bid, 'jid' => jid }, @queue) { ran += 1 }
    end

    assert_equal 0, ran, 'cancelled jobs must not perform'
    refute_nil Wurk::Batch::Status.new(batch.bid).complete_at
    assert_equal 1, callbacks_fired(batch.bid, 'complete')
    assert_equal 1, callbacks_fired(batch.bid, 'success'), 'spec §12: cancelled counts as success'
  end

  def test_invalidated_child_lets_the_parent_fire
    parent, child = nested(parent_cbs: { complete: 'PC' })
    parent.invalidate_all
    ack_success(child.bid, jid_for(@queue, child.bid))
    ack_success(parent.bid, jid_for(@queue, parent.bid))

    assert_equal 1, callbacks_fired(parent.bid, 'complete')
  end

  # A retry of a cancelled job re-pushes into a batch that still knows the jid,
  # so totals don't inflate.
  def test_invalidated_batch_retry_repush_does_not_inflate_totals
    batch = new_batch
    batch.jobs { perform_one }
    batch.invalidate_all
    jid = jid_for(@queue, batch.bid)

    Wurk::Client.push('class' => @class_name, 'args' => [], 'queue' => @queue, 'bid' => batch.bid, 'jid' => jid)
    status = Wurk::Batch::Status.new(batch.bid)

    assert_equal [1, 1], [status.total, status.pending]
  end

  # --- E15: a fire failure never fails a succeeded job --------------------

  def test_fire_error_after_success_neither_raises_nor_records_a_failure
    batch = new_batch(success: 'S')
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)
    reported = []

    with_error_handler(->(ex, ctx, _cfg) { reported << [ex.message, ctx[:bid]] }) do
      with_stub(Wurk::Batch::Callbacks, :maybe_fire, lambda { |orig, bid, **kw|
        bid == batch.bid ? raise('redis blip') : orig.call(bid, **kw)
      }) do
        middleware.call(nil, { 'bid' => batch.bid, 'jid' => jid }, @queue) {}
      end
    end
    status = Wurk::Batch::Status.new(batch.bid)

    assert_equal 0, status.failures
    assert_empty status.failed_jids
    assert_empty live_jids(batch), 'the success ack still landed'
    assert_includes reported, ['redis blip', batch.bid]
  end

  # One transient failure is absorbed by the in-process re-drive.
  def test_transient_fire_error_is_redriven
    batch = new_batch(success: 'S')
    batch.jobs { perform_one }
    failures = 0
    flaky = lambda do |orig, bid, **kw|
      if bid == batch.bid && failures.zero?
        failures += 1
        raise 'blip'
      end
      orig.call(bid, **kw)
    end

    with_stub(Wurk::Batch::Callbacks, :maybe_fire, flaky) { ack_success(batch.bid, jid_for(@queue, batch.bid)) }

    assert_equal 1, callbacks_fired(batch.bid, 'success')
  end

  def test_job_failure_is_still_recorded_and_raised
    batch = new_batch
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)

    assert_raises(RuntimeError) { middleware.call(nil, { 'bid' => batch.bid, 'jid' => jid }, @queue) { raise 'job' } }
    assert_equal [jid], Wurk::Batch::Status.new(batch.bid).failed_jids
  end

  # The hold release at block exit fires like an ack; a failure there is
  # reported, never raised — every job is already pushed, and a caller that
  # retried the block would push them all twice.
  def test_fire_failure_at_block_exit_is_reported_not_raised
    batch = new_batch(success: 'S')
    batch.autoflush = 1
    reported = []

    with_error_handler(->(ex, ctx, _cfg) { reported << [ex.message, ctx[:bid]] }) do
      with_stub(Wurk::Batch::Callbacks, :maybe_fire, lambda { |orig, bid, **kw|
        bid == batch.bid && kw[:live].zero? ? raise('blip') : orig.call(bid, **kw)
      }) do
        batch.jobs do
          perform_one
          ack_success(batch.bid, jid_for(@queue, batch.bid))
        end
      end
    end

    assert_includes reported, ['blip', batch.bid]
    assert_empty live_jids(batch), 'the hold itself was released'
  end

  # --- E16: remove_jobs drains like an ack -------------------------------

  def test_removing_the_last_live_job_fires_the_batch
    batch = new_batch(complete: 'C', success: 'S')
    batch.jobs { 2.times { perform_one } }
    first, second = jids_for(@queue, batch.bid)
    ack_success(batch.bid, first)

    assert_equal 1, batch.remove_jobs(second)
    assert_equal 1, callbacks_fired(batch.bid, 'complete')
    assert_equal 1, callbacks_fired(batch.bid, 'success')
  end

  def test_remove_jobs_is_idempotent_and_clears_failures
    batch = new_batch
    batch.jobs { 2.times { perform_one } }
    first, = jids_for(@queue, batch.bid)
    middleware.call(nil, { 'bid' => batch.bid, 'jid' => first }, @queue) { raise 'x' } rescue nil # rubocop:disable Style/RescueModifier

    assert_equal 1, batch.remove_jobs(first, 'nope')
    assert_equal 0, batch.remove_jobs(first)
    status = Wurk::Batch::Status.new(batch.bid)

    assert_equal [1, 1, 0], [status.total, status.pending, status.failures]
  end

  # --- E18: Status#delete detaches from the parent ------------------------

  def test_deleting_the_last_running_child_fires_the_parent
    parent, child = nested(parent_cbs: { complete: 'PC', success: 'PS' })
    ack_success(parent.bid, jid_for(@queue, parent.bid))

    assert_equal 0, callbacks_fired(parent.bid, 'complete')

    Wurk::Batch::Status.new(child.bid).delete

    assert_equal 1, callbacks_fired(parent.bid, 'complete')
    assert_equal 1, callbacks_fired(parent.bid, 'success')
    assert_equal 0, Wurk::Batch::Status.new(parent.bid).child_count
  end

  def test_deleting_a_child_of_a_busy_parent_does_not_fire_it
    parent, child = nested(parent_cbs: { complete: 'PC' })
    Wurk::Batch::Status.new(child.bid).delete

    assert_equal 0, callbacks_fired(parent.bid, 'complete')
    assert_equal(0, @pool.with { |c| c.call('SCARD', "b-#{parent.bid}-pkids") })
  end

  # --- E19: tag index lifetime -------------------------------------------

  def test_tag_index_has_a_ttl_and_delete_unindexes_the_batch
    tag = "gate-#{Process.pid}-#{object_id}"
    @tags << tag
    batch = new_batch
    batch.tags = [tag]
    batch.jobs { perform_one }

    assert_operator @pool.with { |c| c.call('TTL', "tags:#{tag}") }, :>, 0

    Wurk::Batch::Status.new(batch.bid).delete

    assert_equal(0, @pool.with { |c| c.call('SISMEMBER', "tags:#{tag}", batch.bid) })
  end

  def test_tag_index_ttl_only_ever_extends
    tag = "gate-ext-#{Process.pid}-#{object_id}"
    @tags << tag
    long = new_batch
    long.tags = [tag]
    long.expires_in(10_000)
    long.jobs { perform_one }
    short = new_batch
    short.tags = [tag]
    short.expires_in(100)
    short.jobs { perform_one }

    assert_operator @pool.with { |c| c.call('TTL', "tags:#{tag}") }, :>, 9_000
  end

  # --- E26: re-run after a kill between ack and fire ----------------------

  def test_rerun_after_a_kill_between_ack_and_fire_fires_exactly_once
    batch = new_batch(complete: 'C', success: 'S')
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)
    @pool.with { |c| Wurk::Batch.ack_success(c, batch.bid, jid) } # the ack landed; the process died

    assert_equal 0, callbacks_fired(batch.bid, 'complete')

    2.times { ack_success(batch.bid, jid) } # reclaimed re-runs

    assert_equal 1, callbacks_fired(batch.bid, 'complete')
    assert_equal 1, callbacks_fired(batch.bid, 'success')
  end

  def test_rerun_into_a_deleted_batch_fires_nothing
    batch = new_batch(complete: 'C')
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)
    Wurk::Batch::Status.new(batch.bid).delete

    ack_success(batch.bid, jid)

    assert_equal 0, callbacks_fired(batch.bid, 'complete')
    assert_equal(0, @pool.with { |c| c.call('EXISTS', "b-#{batch.bid}") })
  end

  # --- E29: the death ack is re-driven ------------------------------------

  def test_death_ack_failure_is_retried_and_the_batch_completes
    batch = new_batch(complete: 'C', death: 'D')
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)

    fail_once(:batch_ack_complete, batch.bid, apply_first: false) { kill(batch.bid, jid) }

    assert_equal 1, callbacks_fired(batch.bid, 'complete')
    assert_equal 1, callbacks_fired(batch.bid, 'death')
  end

  # The lost-reply case: the ack applied but its reply never came back, so the
  # replay sees first_death == 0 — :death must still fire, exactly once.
  def test_death_ack_replay_after_a_lost_reply_still_fires_death_once
    batch = new_batch(complete: 'C', death: 'D')
    batch.jobs { perform_one }
    jid = jid_for(@queue, batch.bid)

    fail_once(:batch_ack_complete, batch.bid, apply_first: true) { kill(batch.bid, jid) }

    assert_equal 1, callbacks_fired(batch.bid, 'death')
    assert_equal 1, callbacks_fired(batch.bid, 'complete')
    assert_equal [jid], Wurk::Batch::Status.new(batch.bid).dead_jids
  end

  # --- E30: callbacks stored byte-exact ------------------------------------

  def test_callback_options_round_trip_exactly_through_a_reopen
    batch = new_batch
    early = { 'id' => 12_345_678_901_234_567, 'list' => [], 'path' => 'a/b' }
    late  = { 'id' => 98_765_432_109_876_543, 'empty' => {}, 'nested' => [[]] }
    batch.on(:success, 'Early', early)
    batch.jobs { perform_one }
    Wurk::Batch.new(batch.bid).on(:success, 'Late', late)
    ack_success(batch.bid, jid_for(@queue, batch.bid))

    fired = callback_jobs(batch.bid).to_h { |j| [j['args'][1], j['args'][3]] }

    assert_equal({ 'Early' => early, 'Late' => late }, fired)
  end

  # --- E24: one pipeline for Status#data -----------------------------------

  def test_status_data_reports_sets_and_completion
    parent, child = nested
    jid = jid_for(@queue, child.bid)
    middleware.call(nil, { 'bid' => child.bid, 'jid' => jid }, @queue) { raise 'x' } rescue nil # rubocop:disable Style/RescueModifier
    data = Wurk::Batch::Status.new(parent.bid).data

    assert_equal 1, data['child_count']
    refute data['complete']
    assert_equal [jid], Wurk::Batch::Status.new(child.bid).data['failed_jids']
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

  def queued(queue)
    @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, -1) }.map { |s| JSON.parse(s) }
  end

  def jid_for(queue, bid)
    queued(queue).find { |j| j['bid'] == bid }.fetch('jid')
  end

  def jids_for(queue, bid)
    queued(queue).select { |j| j['bid'] == bid }.map { |j| j['jid'] }
  end

  def live_jids(batch)
    @pool.with { |c| c.call('SMEMBERS', "b-#{batch.bid}-jids") }
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

  # Makes the first `script` call against this bid raise — after applying it
  # when `apply_first` (a reply lost on the way back), before otherwise.
  def fail_once(script, bid, apply_first:, &)
    failed = false
    impl = lambda do |orig, conn, name, keys:, argv:|
      return orig.call(conn, name, keys: keys, argv: argv) if failed || name != script || keys.first != "b-#{bid}"

      failed = true
      orig.call(conn, name, keys: keys, argv: argv) if apply_first
      raise RedisClient::ConnectionError, 'lost'
    end
    with_stub(Wurk::Lua::Loader, :eval_cached, impl, &)
  end
end
