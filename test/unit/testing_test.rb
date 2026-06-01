# frozen_string_literal: true

require_relative '../test_helper'

# Wurk::Testing inline/fake/disable modes + the Sidekiq::Testing helper surface.
# The mode flag and the in-memory Queues store are process-global, but the
# parallel runner forks, so each worker has its own copy — teardown still resets
# both so sequential tests in the same fork don't leak.
class TestingModesTest < Wurk::Test::UnitCase
  parallelize_me!

  class FakeJob
    include Wurk::Job

    sidekiq_options queue: 'testq'

    def self.ran
      @ran ||= []
    end

    def perform(arg)
      self.class.ran << arg
    end
  end

  class BoomJob
    include Wurk::Job

    def perform(*)
      raise 'boom'
    end
  end

  def setup
    super
    FakeJob.ran.clear
  end

  def teardown
    Wurk::Testing.disable!
    Wurk::Queues.clear_all
    Thread.current[Wurk::Testing::THREAD_KEY] = nil
  ensure
    super
  end

  # --- fake mode ----------------------------------------------------------

  def test_fake_collects_jobs_without_running
    Wurk::Testing.fake! do
      FakeJob.perform_async(1)
      FakeJob.perform_async(2)
    end

    assert_equal 2, FakeJob.jobs.size
    assert_empty FakeJob.ran
    assert_equal([1, 2], FakeJob.jobs.map { |j| j['args'].first })
  end

  def test_fake_push_returns_a_jid
    jid = Wurk::Testing.fake! { FakeJob.perform_async(1) }

    assert_kind_of String, jid
    assert_equal 24, jid.length
  end

  def test_fake_payload_carries_wire_fields
    Wurk::Testing.fake! { FakeJob.perform_async(7) }
    job = FakeJob.jobs.first

    assert_equal({ 'class' => 'TestingModesTest::FakeJob', 'queue' => 'testq', 'args' => [7] },
                 job.slice('class', 'queue', 'args'))
    assert_kind_of String, job['jid']
    assert_kind_of Integer, job['enqueued_at']
  end

  def test_drain_runs_and_clears
    Wurk::Testing.fake! do
      FakeJob.perform_async(1)
      FakeJob.perform_async(2)
    end

    assert_equal 2, FakeJob.drain
    assert_equal [1, 2], FakeJob.ran
    assert_empty FakeJob.jobs
  end

  def test_perform_one_runs_first_then_raises_when_empty
    Wurk::Testing.fake! { FakeJob.perform_async(9) }
    FakeJob.perform_one

    assert_equal [9], FakeJob.ran
    assert_raises(Wurk::Testing::EmptyQueueError) { FakeJob.perform_one }
  end

  def test_clear_drops_only_this_class
    Wurk::Testing.fake! do
      FakeJob.perform_async(1)
      BoomJob.perform_async
    end
    FakeJob.clear

    assert_empty FakeJob.jobs
    assert_equal 1, BoomJob.jobs.size
  end

  # --- inline mode --------------------------------------------------------

  def test_inline_runs_immediately
    Wurk::Testing.inline! { FakeJob.perform_async(42) }

    assert_equal [42], FakeJob.ran
    assert_empty FakeJob.jobs
  end

  def test_inline_propagates_job_errors
    error = assert_raises(RuntimeError) { Wurk::Testing.inline! { BoomJob.perform_async } }

    assert_equal 'boom', error.message
  end

  # --- module-level helpers ----------------------------------------------

  def test_worker_drain_all_runs_every_class
    Wurk::Testing.fake! do
      FakeJob.perform_async(1)
      FakeJob.perform_async(2)
    end

    assert_equal 2, Wurk::Worker.drain_all
    assert_equal [1, 2], FakeJob.ran
  end

  def test_worker_clear_all_empties_the_store
    Wurk::Testing.fake! { FakeJob.perform_async(1) }
    Wurk::Worker.clear_all

    assert_empty Wurk::Worker.jobs
  end

  # --- mode plumbing ------------------------------------------------------

  def test_block_form_restores_previous_mode
    Wurk::Testing.disable!

    Wurk::Testing.fake! { assert_predicate Wurk::Testing, :fake? }

    assert_predicate Wurk::Testing, :disabled?
  end

  def test_predicate_helpers
    Wurk::Testing.inline! do
      assert_predicate Wurk::Testing, :enabled?
      refute_predicate Wurk::Testing, :disabled?
      assert_predicate Wurk::Testing, :inline?
    end
  end

  # --- Sidekiq drop-in aliases -------------------------------------------

  def test_sidekiq_aliases
    assert_same Wurk::Testing, Sidekiq::Testing
    assert_same Wurk::Queues, Sidekiq::Queues
    assert_same Wurk::Testing::EmptyQueueError, Sidekiq::EmptyQueueError
  end

  def test_sidekiq_testing_bang_delegates
    Sidekiq::Testing.fake! { FakeJob.perform_async(5) }

    assert_equal 1, FakeJob.jobs.size
  end
end
