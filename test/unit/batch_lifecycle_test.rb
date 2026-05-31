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
    batch = track(Wurk::Batch.new)
    mid_total = nil
    batch.jobs do
      perform_one(batch)
      mid_total = status(batch).total
    end

    assert_equal 1, mid_total
  end

  def test_autoflush_true_buffers_until_block_exit
    batch = track(Wurk::Batch.new)
    batch.autoflush = true
    mid_total = mid_queue = nil
    batch.jobs do
      3.times { perform_one(batch) }
      mid_total = status(batch).total
      mid_queue = @pool.with { |c| c.call('LLEN', "queue:#{@queue}") }
    end

    assert_equal 0, mid_total, 'jobs must stay buffered inside the block'
    assert_equal 0, mid_queue
    assert_equal 3, status(batch).total
    assert_equal 3, @pool.with { |c| c.call('LLEN', "queue:#{@queue}") }
  end

  def test_autoflush_integer_flushes_every_n_jobs
    batch = track(Wurk::Batch.new)
    batch.autoflush = 2
    totals = []
    batch.jobs do
      4.times do
        perform_one(batch)
        totals << status(batch).total
      end
    end

    assert_equal [0, 2, 2, 4], totals
    assert_equal 4, status(batch).total
  end

  def test_autoflush_empty_block_still_enqueues_marker
    batch = track(Wurk::Batch.new)
    batch.autoflush = true
    batch.jobs {} # rubocop:disable Lint/EmptyBlock

    assert_operator status(batch).total, :>=, 1
  end

  # --- linger ------------------------------------------------------------

  def test_success_applies_default_linger_retention
    batch = track(Wurk::Batch.new)
    batch.jobs { perform_one(batch) }
    ack_success(batch.bid, jid_for(@queue, batch.bid))

    ttl = @pool.with { |c| c.call('TTL', "b-#{batch.bid}") }

    assert_operator ttl, :<=, Wurk::Batch::POST_SUCCESS_EXPIRY_SECONDS
    assert_operator ttl, :>, Wurk::Batch::POST_SUCCESS_EXPIRY_SECONDS - 60
  end

  def test_success_applies_per_batch_linger_override
    batch = track(Wurk::Batch.new)
    batch.linger = 120
    batch.jobs { perform_one(batch) }
    ack_success(batch.bid, jid_for(@queue, batch.bid))

    ttl = @pool.with { |c| c.call('TTL', "b-#{batch.bid}") }

    assert_operator ttl, :<=, 120
    assert_operator ttl, :>, 60
  end

  def test_linger_round_trips_on_reopen
    batch = track(Wurk::Batch.new)
    batch.linger = 300
    batch.jobs { perform_one(batch) }

    assert_equal 300, Wurk::Batch.new(batch.bid).linger
  end

  # --- callback lifecycle ------------------------------------------------

  def test_success_and_complete_fire_when_all_jobs_succeed
    batch = track(Wurk::Batch.new)
    batch.callback_queue = @cbq
    batch.on(:success, 'S')
    batch.on(:complete, 'C')
    batch.jobs { perform_one(batch) }

    ack_success(batch.bid, jid_for(@queue, batch.bid))

    assert_equal 1, callback_jobs(event: 'success', bid: batch.bid).size
    assert_equal 1, callback_jobs(event: 'complete', bid: batch.bid).size
  end

  def test_complete_fires_but_success_does_not_on_death
    batch = track(Wurk::Batch.new)
    batch.callback_queue = @cbq
    batch.on(:success, 'S')
    batch.on(:complete, 'C')
    batch.on(:death, 'D')
    batch.jobs { perform_one(batch) }

    kill(batch.bid, jid_for(@queue, batch.bid))

    assert_equal 1, callback_jobs(event: 'death', bid: batch.bid).size
    assert_equal 1, callback_jobs(event: 'complete', bid: batch.bid).size
    assert_equal 0, callback_jobs(event: 'success', bid: batch.bid).size
  end

  def test_death_fires_exactly_once_across_multiple_deaths
    batch = track(Wurk::Batch.new)
    batch.callback_queue = @cbq
    batch.on(:death, 'D')
    batch.jobs { 2.times { perform_one(batch) } }
    jids = queued(@queue).select { |j| j['bid'] == batch.bid }.map { |j| j['jid'] }

    kill(batch.bid, jids[0])
    kill(batch.bid, jids[1])

    assert_equal 1, callback_jobs(event: 'death', bid: batch.bid).size
    assert_includes dead_batches, batch.bid
  end

  # --- nested death cascade ----------------------------------------------

  def test_child_death_fires_parent_death_callback_exactly_once
    parent = track(Wurk::Batch.new)
    parent.callback_queue = @cbq
    parent.on(:death, 'ParentDeath')
    child = nil
    parent.jobs do
      perform_one(parent)
      child = track(Wurk::Batch.new)
      child.callback_queue = @cbq
      child.on(:death, 'ChildDeath')
      child.jobs { perform_one(child) }
    end

    kill(child.bid, jid_for(@queue, child.bid))

    assert_equal 1, callback_jobs(event: 'death', bid: child.bid).size
    assert_equal 1, callback_jobs(event: 'death', bid: parent.bid).size
    assert_includes dead_batches, parent.bid
    assert_includes dead_batches, child.bid
  end

  def test_child_death_suppresses_parent_success
    parent = track(Wurk::Batch.new)
    parent.callback_queue = @cbq
    parent.on(:success, 'ParentSuccess')
    parent.on(:death, 'ParentDeath')
    child = nil
    parent.jobs do
      perform_one(parent)
      child = track(Wurk::Batch.new)
      child.callback_queue = @cbq
      child.jobs { perform_one(child) }
    end

    # Child dies first, then the parent's own job succeeds — success must
    # stay suppressed because the subtree had a death.
    kill(child.bid, jid_for(@queue, child.bid))
    ack_success(parent.bid, jid_for(@queue, parent.bid))

    assert_equal 0, callback_jobs(event: 'success', bid: parent.bid).size
    assert_equal 1, callback_jobs(event: 'death', bid: parent.bid).size
  end

  def test_deep_death_cascades_through_every_ancestor
    grand = track(Wurk::Batch.new)
    grand.callback_queue = @cbq
    grand.on(:death, 'GrandDeath')
    parent = child = nil
    grand.jobs do
      perform_one(grand)
      parent = track(Wurk::Batch.new)
      parent.callback_queue = @cbq
      parent.jobs do
        perform_one(parent)
        child = track(Wurk::Batch.new)
        child.callback_queue = @cbq
        child.jobs { perform_one(child) }
      end
    end

    kill(child.bid, jid_for(@queue, child.bid))

    assert_includes dead_batches, parent.bid
    assert_includes dead_batches, grand.bid
    assert_equal 1, callback_jobs(event: 'death', bid: grand.bid).size
  end

  # --- per-callback rescue ----------------------------------------------

  def test_failing_callback_enqueue_does_not_strand_remaining_callbacks
    batch = track(Wurk::Batch.new)
    batch.callback_queue = @cbq
    batch.on(:complete, 'CbA')
    batch.on(:complete, 'CbB')
    batch.jobs { perform_one(batch) }

    attempted = []
    raising_push = lambda do |item|
      attempted << item['args'][1]
      raise 'boom' if attempted.size == 1
    end
    with_push_override(raising_push) do
      Wurk::Batch::Callbacks.fire_complete(batch.bid)
    end

    assert_equal %w[CbA CbB], attempted, 'both callbacks must be attempted despite the first raising'
  end

  private

  def track(batch)
    @bids << batch.bid
    batch
  end

  def status(batch)
    Wurk::Batch::Status.new(batch.bid)
  end

  # Push through Wurk::Client so the batch client middleware runs and the
  # active Thread.current[Wurk::Batch::THREAD_KEY] (set inside #jobs) stamps
  # the bid + routes through BATCH_PUSH (or the autoflush buffer).
  def perform_one(_batch)
    Wurk::Client.push('class' => @class_name, 'args' => [], 'queue' => @queue)
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

  def callback_jobs(event:, bid:)
    queued(@cbq).select do |j|
      j['class'] == 'Wurk::Batch::CallbackJob' && j['args'][0] == bid && j['args'][2] == event
    end
  end

  def dead_batches
    @pool.with { |c| c.call('ZRANGE', 'dead-batches', 0, -1) }
  end

  # Minitest 6 dropped #stub, so swap Wurk::Client.push for the duration of
  # the block and restore it. Safe under the suite's fork-based parallelism.
  def with_push_override(replacement)
    original = Wurk::Client.singleton_method(:push)
    Wurk::Client.singleton_class.send(:define_method, :push, replacement)
    yield
  ensure
    Wurk::Client.singleton_class.send(:define_method, :push, original)
  end
end
