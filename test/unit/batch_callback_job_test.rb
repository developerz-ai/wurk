# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Collector for the callback targets below. Tests within a UnitCase run
# serially, but the mutex keeps this honest if that ever changes.
module WurkBatchCbRecorder
  MUTEX = Mutex.new
  CALLS = Hash.new { |h, k| h[k] = [] }

  def self.record(name, status, options)
    MUTEX.synchronize { CALLS[status.bid] << [name, options] }
  end

  def self.calls_for(bid)
    MUTEX.synchronize { CALLS[bid].dup }
  end
end

# Resolution runs through `Object.const_get`, so the targets must be real
# top-level constants — an anonymous class with a stubbed `name` is not
# resolvable and would prove nothing.
class WurkBatchCbTarget
  def on_success(status, options) = WurkBatchCbRecorder.record(:on_success, status, options)
  def on_complete(status, options) = WurkBatchCbRecorder.record(:on_complete, status, options)
  def on_death(status, options) = WurkBatchCbRecorder.record(:on_death, status, options)
  def shipped(status, options) = WurkBatchCbRecorder.record(:shipped, status, options)
  def capture(status, options) = WurkBatchCbRecorder.record(status.class, status, options)

  private

  def hidden(status, options) = WurkBatchCbRecorder.record(:hidden, status, options)
end

# Resolvable, instantiable, and carrying none of the callback methods.
class WurkBatchCbBare
  def some_other_method; end
end

# Drives Wurk::Batch::CallbackJob against real Redis. Asserts the target-spec
# forms of docs/target/sidekiq-pro.md §2.2/§2.4 — bare class name, "Klass#method",
# and the class-less "#method" that takes its class from the batch's
# `callback_class` — plus what happens when a spec resolves to nothing.
class BatchCallbackJobTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @pool = Wurk.configuration.redis_pool
    @class_name = "BatchCbJob@#{Process.pid}-#{object_id}"
    @queue = "cbq-#{Process.pid}-#{object_id}"
    @bids = []
  end

  def teardown
    @pool.with do |conn|
      @bids.uniq.each do |bid|
        conn.call('UNLINK', *Wurk::Batch.keys_for(bid))
        conn.call('ZREM', 'batches', bid)
      end
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
    end
  ensure
    super
  end

  # --- target spec forms -------------------------------------------------

  def test_class_name_spec_invokes_on_event
    bid = batch_with(nil).bid

    perform(bid, 'WurkBatchCbTarget', 'success', 'k' => 1)

    assert_equal [[:on_success, { 'k' => 1 }]], WurkBatchCbRecorder.calls_for(bid)
  end

  def test_class_name_spec_derives_the_method_from_the_event
    bid = batch_with(nil).bid

    perform(bid, 'WurkBatchCbTarget', 'complete', {})
    perform(bid, 'WurkBatchCbTarget', 'death', {})

    assert_equal %i[on_complete on_death], WurkBatchCbRecorder.calls_for(bid).map(&:first)
  end

  def test_klass_hash_method_spec_invokes_the_named_method
    bid = batch_with(nil).bid

    perform(bid, 'WurkBatchCbTarget#shipped', 'success', 'oid' => 7)

    assert_equal [[:shipped, { 'oid' => 7 }]], WurkBatchCbRecorder.calls_for(bid)
  end

  # The defect: `callback_class` was stored, round-tripped, and never read, so
  # a class-less spec silently never fired.
  def test_class_less_spec_resolves_via_the_batch_callback_class
    bid = batch_with('WurkBatchCbTarget').bid

    perform(bid, '#shipped', 'success', 'oid' => 9)

    assert_equal [[:shipped, { 'oid' => 9 }]], WurkBatchCbRecorder.calls_for(bid)
  end

  def test_class_less_spec_resolves_when_callback_class_was_set_as_a_class
    bid = batch_with(WurkBatchCbTarget).bid

    perform(bid, '#shipped', 'complete', {})

    assert_equal [[:shipped, {}]], WurkBatchCbRecorder.calls_for(bid)
  end

  # The recorder keys on `status.bid`, so a hit under this bid already proves
  # the Status was built for this batch; assert its type too.
  def test_callback_receives_a_status_for_its_own_batch
    bid = batch_with(nil).bid

    perform(bid, 'WurkBatchCbTarget#capture', 'success', {})

    assert_equal [[Wurk::Batch::Status, {}]], WurkBatchCbRecorder.calls_for(bid)
  end

  def test_nil_options_become_an_empty_hash
    bid = batch_with(nil).bid

    Wurk::Batch::CallbackJob.new.perform(bid, 'WurkBatchCbTarget#shipped', 'success', nil)

    assert_equal [[:shipped, {}]], WurkBatchCbRecorder.calls_for(bid)
  end

  # --- end to end through the enqueue path -------------------------------

  # The full path: `on` persists the spec, Callbacks enqueues a CallbackJob,
  # the payload is JSON in Redis, and performing it from the parsed args must
  # still resolve. Guards the class-less form against a JSON round trip.
  def test_class_less_spec_survives_the_enqueue_round_trip
    batch = batch_with('WurkBatchCbTarget')
    batch.on(:success, '#shipped', 'oid' => 11)

    Wurk::Batch::Callbacks.enqueue_callbacks(batch.bid, 'success')
    args = enqueued_callback_args(batch.bid)

    assert_equal [batch.bid, '#shipped', 'success', { 'oid' => 11 }], args

    Wurk::Batch::CallbackJob.new.perform(*args)

    assert_equal [[:shipped, { 'oid' => 11 }]], WurkBatchCbRecorder.calls_for(batch.bid)
  end

  # --- unresolvable targets ----------------------------------------------

  def test_unknown_constant_raises_unresolvable_target
    bid = batch_with(nil).bid

    error = assert_raises(Wurk::Batch::CallbackJob::UnresolvableTarget) do
      perform(bid, 'NoSuchCallbackConstant', 'success', {})
    end

    assert_match(/NoSuchCallbackConstant/, error.message)
  end

  def test_unknown_constant_in_klass_hash_method_spec_raises_unresolvable_target
    bid = batch_with(nil).bid

    assert_raises(Wurk::Batch::CallbackJob::UnresolvableTarget) do
      perform(bid, 'NoSuchCallbackConstant#shipped', 'success', {})
    end
  end

  def test_class_less_spec_without_callback_class_raises_unresolvable_target
    bid = batch_with(nil).bid

    error = assert_raises(Wurk::Batch::CallbackJob::UnresolvableTarget) do
      perform(bid, '#shipped', 'success', {})
    end

    assert_match(/callback_class/, error.message)
  end

  def test_missing_method_raises_unresolvable_target
    bid = batch_with(nil).bid

    error = assert_raises(Wurk::Batch::CallbackJob::UnresolvableTarget) do
      perform(bid, 'WurkBatchCbTarget#no_such_method', 'success', {})
    end

    assert_match(/no_such_method/, error.message)
  end

  def test_private_method_raises_unresolvable_target
    bid = batch_with(nil).bid

    assert_raises(Wurk::Batch::CallbackJob::UnresolvableTarget) do
      perform(bid, 'WurkBatchCbTarget#hidden', 'success', {})
    end
  end

  def test_missing_on_event_method_raises_unresolvable_target
    bid = batch_with(nil).bid

    error = assert_raises(Wurk::Batch::CallbackJob::UnresolvableTarget) do
      perform(bid, 'WurkBatchCbBare', 'success', {})
    end

    assert_match(/on_success/, error.message)
  end

  # A constant that resolves to something you can't instantiate is just as
  # unrecoverable as one that doesn't resolve at all — same treatment.
  def test_non_class_constant_raises_unresolvable_target
    bid = batch_with(nil).bid

    error = assert_raises(Wurk::Batch::CallbackJob::UnresolvableTarget) do
      perform(bid, 'WurkBatchCbRecorder', 'success', {})
    end

    assert_match(/not a Class/, error.message)
  end

  # An unresolvable target never heals, so it goes to the dead set on the
  # first attempt instead of crash-looping for ~21 days. Anything else the
  # callback raises keeps the default backoff.
  def test_retry_policy_kills_unresolvable_targets_only
    block = Wurk::Batch::CallbackJob.sidekiq_retry_in_block

    assert_equal :kill, block.call(0, Wurk::Batch::CallbackJob::UnresolvableTarget.new, {})
    assert_nil block.call(0, RuntimeError.new('callback blew up'), {})
  end

  private

  def perform(bid, spec, event, options)
    Wurk::Batch::CallbackJob.new.perform(bid, spec, event, options)
  end

  def batch_with(callback_class)
    batch = Wurk::Batch.new
    @bids << batch.bid
    batch.callback_queue = @queue
    batch.callback_class = callback_class
    batch.jobs { Wurk::Client.push('class' => @class_name, 'args' => [], 'queue' => @queue) }
    batch
  end

  def enqueued_callback_args(bid)
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }
         .map { |raw| JSON.parse(raw) }
         .find { |job| job['class'] == 'Wurk::Batch::CallbackJob' && job['args'][0] == bid }
         &.fetch('args')
  end
end
