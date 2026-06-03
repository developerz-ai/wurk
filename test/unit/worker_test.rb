# frozen_string_literal: true

require_relative '../test_helper'

class WorkerTest < Wurk::Test::UnitCase
  parallelize_me!

  class BatchWorker
    include Wurk::Worker

    def perform; end
  end

  # --- batch (line 55: @bid.nil? then/else) ----------------------------

  def test_batch_returns_nil_without_bid
    assert_nil BatchWorker.new.batch
  end

  def test_batch_returns_batch_when_bid_present
    bid = real_batch_bid
    worker = BatchWorker.new
    worker.bid = bid

    batch = worker.batch

    assert_kind_of Wurk::Batch, batch
    assert_equal bid, batch.bid
  end

  # --- valid_within_batch? (line 63: @bid.nil? then/else) --------------

  def test_valid_within_batch_true_without_bid
    assert_predicate BatchWorker.new, :valid_within_batch?
  end

  def test_valid_within_batch_true_for_live_batch
    worker = BatchWorker.new
    worker.bid = real_batch_bid

    assert_predicate worker, :valid_within_batch?
  end

  def test_valid_within_batch_false_for_invalidated_batch
    bid = real_batch_bid
    Wurk.redis { |c| c.call('HSET', "b-#{bid}", 'invalidated', '1') }
    worker = BatchWorker.new
    worker.bid = bid

    refute_predicate worker, :valid_within_batch?
  end

  # --- bid accessor ----------------------------------------------------

  def test_bid_writer_and_reader_roundtrip
    worker = BatchWorker.new
    worker.bid = 'b123'

    assert_equal 'b123', worker.bid
  end

  # --- process_job sets bid (line 172 then) ----------------------------

  def test_process_job_assigns_bid_to_worker
    bid = real_batch_bid
    klass = Class.new(BatchWorker)
    seen_bid = nil
    klass.define_method(:perform) { |*| seen_bid = self.bid }

    klass.process_job('jid' => 'j1', 'bid' => bid, 'args' => [], 'queue' => 'default')

    assert_equal bid, seen_bid
  end

  # line 172 else (instance does not respond to bid=) is unreachable through
  # the public API: process_job is a ClassMethod only present on classes that
  # `include Wurk::Worker`, and that include always defines `attr_writer :bid`,
  # so every instance responds to bid=. No deterministic way to drive the else
  # without faking the receiver, which the no-mock rule forbids.

  # --- inherited_sidekiq_options (line 199 then/else) ------------------
  # then: superclass responds to get_sidekiq_options (subclass of a Worker).
  # else: superclass is Object (direct include).

  def test_inherited_options_falls_back_to_worker_superclass
    parent = Class.new do
      include Wurk::Worker

      sidekiq_options queue: 'from_parent', retry: 7
    end
    child = Class.new(parent)
    # `inherited` pre-seeds @sidekiq_options_hash; clear it so get_sidekiq_options
    # must recompute via inherited_sidekiq_options, exercising the then branch.
    child.remove_instance_variable(:@sidekiq_options_hash)

    opts = child.get_sidekiq_options

    assert_equal 'from_parent', opts['queue']
    assert_equal 7, opts['retry']
  end

  def test_inherited_options_falls_back_to_defaults_for_direct_include
    klass = Class.new { include Wurk::Worker }
    klass.remove_instance_variable(:@sidekiq_options_hash) if
      klass.instance_variable_defined?(:@sidekiq_options_hash)

    opts = klass.get_sidekiq_options

    assert_equal Wurk.default_job_options['queue'], opts['queue']
  end

  private

  # Allocate a real, flushed batch and return its bid. Uses real Redis via the
  # configured pool (no mocking).
  def real_batch_bid
    batch = Wurk::Batch.new
    batch.jobs { BatchWorker.perform_async }
    batch.bid
  end
end
