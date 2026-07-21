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

  # The flip side — that the require DOES warn and enable fake mode from a
  # clean process — is process-global and one-way, so it lives in
  # test/unit/testing_require_test.rb as a subprocess test.
  def test_deprecated_require_respects_an_explicit_mode
    Wurk::Testing.disable!

    out = capture_io { Wurk::Testing.deprecated_require! }.last

    assert_empty out, 'must not warn once the suite has chosen a mode'
    assert_predicate Wurk::Testing, :disabled?, 'must not override an explicit disable!'
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

  def test_nested_block_modes_raise
    Wurk::Testing.fake! do
      assert_raises(Wurk::Testing::TestModeAlreadySetError) do
        Wurk::Testing.inline! { :never }
      end
    end
  end

  def test_queues_index_returns_a_live_reference
    Wurk::Testing.fake! { FakeJob.perform_async(1) }
    Wurk::Queues['testq'].clear

    assert_empty FakeJob.jobs
  end

  def test_predicate_helpers
    Wurk::Testing.inline! do
      assert_predicate Wurk::Testing, :enabled?
      refute_predicate Wurk::Testing, :disabled?
      assert_predicate Wurk::Testing, :inline?
    end
  end

  # --- perform_inline middleware ------------------------------------------
  # perform_inline used to call `perform` directly, so a unique-jobs lock taken
  # by client middleware was never released by its server counterpart and batch
  # callbacks never fired. It now runs both real chains, like Sidekiq.

  class RecordingClientMiddleware
    def self.calls = @calls ||= []

    def call(job_class, item, queue, _pool)
      self.class.calls << [job_class, item['args'], queue]
      yield
    end
  end

  class RecordingServerMiddleware
    def self.calls = @calls ||= []

    def call(worker, job, queue)
      self.class.calls << [worker.jid, job['args'], queue]
      yield
    end
  end

  class HaltingClientMiddleware
    def call(*)
      nil
    end
  end

  def with_middleware(client: nil, server: nil)
    config = Wurk.configuration
    config.client_middleware.add(client) if client
    config.server_middleware.add(server) if server
    yield
  ensure
    config.client_middleware.remove(client) if client
    config.server_middleware.remove(server) if server
  end

  def test_perform_inline_runs_client_middleware
    RecordingClientMiddleware.calls.clear

    with_middleware(client: RecordingClientMiddleware) { FakeJob.perform_inline(11) }

    assert_equal [['TestingModesTest::FakeJob', [11], 'testq']], RecordingClientMiddleware.calls
  end

  def test_perform_inline_runs_server_middleware_around_a_jid_bearing_instance
    RecordingServerMiddleware.calls.clear

    with_middleware(server: RecordingServerMiddleware) { FakeJob.perform_inline(11) }
    jid, args, queue = RecordingServerMiddleware.calls.fetch(0)

    assert_equal [String, [11], 'testq'], [jid.class, args, queue]
    assert_equal [11], FakeJob.ran
  end

  def test_perform_inline_returns_true_when_the_job_runs
    assert FakeJob.perform_inline(14)
  end

  def test_setter_perform_inline_runs_server_middleware_with_its_queue
    RecordingServerMiddleware.calls.clear

    with_middleware(server: RecordingServerMiddleware) do
      FakeJob.set(queue: 'override').perform_inline(12)
    end

    assert_equal [12], FakeJob.ran
    assert_equal 'override', RecordingServerMiddleware.calls.fetch(0).last
  end

  def test_perform_inline_halted_by_client_middleware_does_not_run
    result = with_middleware(client: HaltingClientMiddleware) { FakeJob.perform_inline(13) }

    assert_nil result
    assert_empty FakeJob.ran
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
