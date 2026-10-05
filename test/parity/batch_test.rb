# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'securerandom'

# Parity oracle for Sidekiq Pro batches, written from
# docs/target/sidekiq-pro.md §2 (Batches) and §12 (behavioural quirks), not
# from Wurk's implementation. Jobs run through a real `Sidekiq::Processor`
# over the default configuration's server chain and death handlers — the path
# a drop-in app's jobs take — against real Redis.
#
# Enforced:
# - §2.3 `#jobs` is atomic: a block that raises enqueues nothing; an empty
#   block synthesises a `Sidekiq::Batch::Empty` no-op so callbacks still fire.
# - §2.4 `:success`/`:complete`/`:death` semantics, each firing once, with the
#   JSON options handed to `on_<event>(status, options)` intact.
# - §2.4 child `:success` before parent `:success`; §2.9 a step workflow whose
#   callback reopens the parent and adds the next step keeps the parent open
#   until that step and its callback are done.
# - §2.2 `#remove_jobs` returns the count removed and the batch completes
#   without the removed job.
# - §12 jobs cancelled via `invalidate_all` count as success.
# - §2.8 the Redis keys a batch is visible under.
class BatchParityTest < Wurk::Test::UnitCase
  parallelize_me!

  # Process-local event log keyed by a per-test token; jobs and callbacks run
  # on this test's thread, so no Redis round trip is needed to observe them.
  module Log
    MUTEX = Mutex.new
    EVENTS = Hash.new { |h, k| h[k] = [] }

    def self.record(token, event) = MUTEX.synchronize { EVENTS[token] << event }
    def self.events(token) = MUTEX.synchronize { EVENTS[token].dup }
    def self.clear(token) = MUTEX.synchronize { EVENTS.delete(token) }
  end

  class OkJob
    include Sidekiq::Job

    def perform(token, label)
      Log.record(token, label)
    end
  end

  class DyingJob
    include Sidekiq::Job

    def perform(_token)
      raise 'dies'
    end
  end

  # The §2.6 pattern for cancellable work.
  class CancellableJob
    include Sidekiq::Job

    def perform(token, label)
      return unless valid_within_batch?

      Log.record(token, label)
    end
  end

  class Recorder
    def on_success(status, options) = Log.record(options['token'], ['success', status.bid, options])
    def on_complete(status, options) = Log.record(options['token'], ['complete', status.bid, options])
    def on_death(status, options) = Log.record(options['token'], ['death', status.bid, options])
  end

  # §2.9, verbatim in shape: a job opens its own batch; a callback opens its
  # parent.
  class StartWorkflow
    include Sidekiq::Job

    def perform(options)
      Log.record(options['token'], 'start')
      batch.jobs do
        step1 = Sidekiq::Batch.new
        step1.callback_queue = options['cbq']
        step1.on(:success, 'BatchParityTest::Fulfillment#step1_done', options)
        step1.jobs { OkJob.set(queue: options['queue']).perform_async(options['token'], 'A') }
      end
    end
  end

  class Fulfillment
    def step1_done(status, options)
      Log.record(options['token'], 'step1_done')
      parent = Sidekiq::Batch.new(status.parent_bid)
      parent.jobs do
        step2 = Sidekiq::Batch.new
        step2.callback_queue = options['cbq']
        step2.on(:success, 'BatchParityTest::Fulfillment#step2_done', options)
        step2.jobs do
          OkJob.set(queue: options['queue']).perform_async(options['token'], 'B')
          OkJob.set(queue: options['queue']).perform_async(options['token'], 'C')
        end
      end
    end

    def step2_done(_status, options) = Log.record(options['token'], 'step2_done')
    def shipped(_status, options) = Log.record(options['token'], 'shipped')
  end

  def setup
    super
    @token = SecureRandom.hex(6)
    @queue = "bp-#{@token}"
    @cbq   = "bpcb-#{@token}"
    @capsule = Sidekiq::Capsule.new("batch-parity-#{@token}", Sidekiq.default_configuration)
    @capsule.queues = [@queue, @cbq]
    @capsule.fetcher = Sidekiq::BasicFetch.new(@capsule)
    @processor = Sidekiq::Processor.new(@capsule)
    @bids = []
  end

  def teardown
    @capsule.fetcher.flush_pending_acks
    Sidekiq.redis do |c|
      [@queue, @cbq].each { |q| c.call('DEL', "queue:#{q}", Sidekiq::BasicFetch.private_queue_name("queue:#{q}")) }
      @bids.each { |bid| c.call('ZREM', 'batches', bid, 'dead-batches', bid) }
    end
    Log.clear(@token)
  ensure
    super
  end

  # --- §2.4 -----------------------------------------------------------------

  def test_success_and_complete_fire_once_with_their_options
    batch = new_batch
    batch.on(:success, Recorder, 'token' => @token, 'k' => 'v')
    batch.on(:complete, Recorder, 'token' => @token)
    batch.jobs { 2.times { |i| ok(i) } }
    drain

    assert_equal [['success', batch.bid, { 'token' => @token, 'k' => 'v' }]], events_named('success')
    assert_equal 1, events_named('complete').size
    assert_predicate Sidekiq::Batch::Status.new(batch.bid), :complete?
  end

  # §12: a `retry: false` job that raises fires :death (Pro 7.1+); :complete
  # still fires, :success never does.
  def test_a_dead_job_fires_death_and_complete_but_never_success
    batch = new_batch
    %i[success complete death].each { |e| batch.on(e, Recorder, 'token' => @token) }
    batch.jobs do
      ok(1)
      2.times { DyingJob.set(queue: @queue, retry: false).perform_async(@token) }
    end
    drain

    assert_equal 1, events_named('death').size
    assert_equal 1, events_named('complete').size
    assert_empty events_named('success')
    assert_equal 2, Sidekiq::Batch::Status.new(batch.bid).dead_jids.size
  end

  # §2.4: "options is JSON-serialised" — values survive exactly, including for
  # a callback registered after the first flush on a reopened batch.
  def test_callback_options_survive_exactly
    early = { 'token' => @token, 'id' => 12_345_678_901_234_567, 'list' => [], 'path' => 'a/b' }
    late  = { 'token' => @token, 'id' => 98_765_432_109_876_543, 'empty' => {} }
    batch = new_batch
    batch.on(:success, Recorder, early)
    batch.jobs { ok(1) }
    Sidekiq::Batch.new(batch.bid).on(:complete, Recorder, late)
    drain

    assert_equal [early], events_named('success').map(&:last)
    assert_equal [late], events_named('complete').map(&:last)
  end

  # --- §2.3 -----------------------------------------------------------------

  def test_a_raising_jobs_block_enqueues_nothing
    batch = new_batch
    batch.on(:complete, Recorder, 'token' => @token)
    assert_raises(RuntimeError) do
      batch.jobs do
        ok(1)
        raise 'abort'
      end
    end
    drain

    assert_equal 0, Sidekiq::Queue.new(@queue).size
    assert_empty Log.events(@token)
  end

  def test_an_empty_jobs_block_synthesises_an_empty_job_and_fires
    batch = new_batch
    batch.on(:success, Recorder, 'token' => @token)
    batch.jobs {}
    empty = Sidekiq::Queue.new('default').find { |job| job.item['bid'] == batch.bid }

    refute_nil empty, 'no Sidekiq::Batch::Empty job was enqueued'
    assert_equal 'Sidekiq::Batch::Empty', empty.klass

    move_to_test_queue(empty)
    drain

    assert_equal 1, events_named('success').size
  end

  # --- §2.4 ordering / §2.9 nesting -------------------------------------------

  def test_child_success_fires_before_parent_success
    parent = new_batch
    parent.on(:success, Recorder, 'token' => @token)
    child = nil
    parent.jobs do
      ok(1)
      child = new_batch
      child.on(:success, Recorder, 'token' => @token)
      child.jobs { ok(2) }
    end
    drain

    assert_equal([child.bid, parent.bid], events_named('success').map { |e| e[1] })
  end

  def test_step_workflow_parent_waits_for_every_step_and_its_callback
    options = { 'token' => @token, 'queue' => @queue, 'cbq' => @cbq }
    overall = new_batch
    overall.on(:success, 'BatchParityTest::Fulfillment#shipped', options)
    overall.jobs { StartWorkflow.set(queue: @queue).perform_async(options) }
    drain

    log = Log.events(@token)

    assert_equal 1, log.count('shipped'), log.inspect
    assert_equal 'shipped', log.last, "the overall batch fired before its last step: #{log.inspect}"
    assert_operator log.index('step1_done'), :<, log.index('B')
  end

  # --- §2.2 -------------------------------------------------------------------

  def test_remove_jobs_drops_a_job_and_the_batch_completes_without_it
    batch = new_batch
    batch.on(:success, Recorder, 'token' => @token)
    later = nil
    batch.jobs do
      ok(1)
      later = OkJob.set(queue: @queue).perform_in(3600, @token, 'later')
    end
    drain

    assert_empty events_named('success'), 'the scheduled job is still pending'
    assert_equal 1, batch.remove_jobs(later)
    refute_includes batch, later

    drain

    assert_equal 1, events_named('success').size
  ensure
    Sidekiq::ScheduledSet.new.find_job(later)&.delete if later
  end

  # --- §12 --------------------------------------------------------------------

  def test_jobs_cancelled_by_invalidate_all_count_as_success
    batch = new_batch
    batch.on(:success, Recorder, 'token' => @token)
    batch.on(:complete, Recorder, 'token' => @token)
    batch.jobs { 2.times { |i| CancellableJob.set(queue: @queue).perform_async(@token, "work#{i}") } }
    batch.invalidate_all

    refute_predicate batch, :valid?

    drain

    assert_empty(Log.events(@token).grep(/\Awork/), 'cancelled jobs did their work')
    assert_equal 1, events_named('complete').size
    assert_equal 1, events_named('success').size
  end

  # --- §2.8 -------------------------------------------------------------------

  def test_batch_is_visible_under_the_documented_keys
    tag = "bp-tag-#{@token}"
    batch = new_batch
    batch.description = 'parity'
    batch.tags = [tag]
    jid = nil
    batch.jobs { jid = ok(1) }

    Sidekiq.redis do |c|
      assert_equal 'parity', c.call('HGET', "b-#{batch.bid}", 'description')
      assert_equal %w[1 1], c.call('HMGET', "b-#{batch.bid}", 'total', 'pending')
      assert_equal [jid], c.call('SMEMBERS', "b-#{batch.bid}-jids")
      refute_nil c.call('ZSCORE', 'batches', batch.bid)
      assert_equal 1, c.call('SISMEMBER', "tags:#{tag}", batch.bid)
    end
    assert_equal [batch.bid], Sidekiq::BatchSet.new.scan_tags(tag).to_a

    drain

    assert_equal(%w[0 1], Sidekiq.redis { |c| c.call('HMGET', "b-#{batch.bid}", 'pending', 'success') })
  ensure
    Sidekiq.redis { |c| c.call('DEL', "tags:#{tag}") }
  end

  private

  def new_batch
    batch = Sidekiq::Batch.new
    batch.callback_queue = @cbq
    @bids << batch.bid
    batch
  end

  def ok(label)
    OkJob.set(queue: @queue).perform_async(@token, label.to_s)
  end

  def events_named(name)
    Log.events(@token).select { |e| e.is_a?(Array) && e.first == name }
  end

  # Runs everything on this test's two queues until both are empty — jobs,
  # then the callback jobs they cause, then whatever those enqueue.
  def drain(limit: 200)
    limit.times do
      break if Sidekiq.redis { |c| [@queue, @cbq].sum { |q| c.call('LLEN', "queue:#{q}") } }.zero?

      @processor.process_one
    end
    @capsule.fetcher.flush_pending_acks
  end

  def move_to_test_queue(record)
    Sidekiq.redis do |c|
      c.call('LREM', 'queue:default', 1, record.value)
      c.call('LPUSH', "queue:#{@queue}", record.value)
    end
  end
end
