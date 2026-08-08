# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Wurk::Middleware::Status: the `status:<jid>` lifecycle around one execution —
# `running`, the three terminal transitions the middleware can prove, result
# capture, and the two (`retrying`, `dead`) written from JobRetry because only
# JobRetry knows which of them a failure became.
class StatusMiddlewareTest < Wurk::Test::UnitCase
  parallelize_me!

  # EVALSHA counts as one command only against a warm script cache; a cold one
  # pays NOSCRIPT + SCRIPT LOAD + retry and the round-trip assertions read three.
  def setup
    super
    @jid = SecureRandom.hex(12)
    @queue = "status-mw-#{SecureRandom.hex(4)}"
    Wurk.redis { |conn| Wurk::Lua::Loader.script_load_all(conn) }
  end

  def teardown
    Wurk.redis { |c| c.call('UNLINK', Wurk::Status.key(@jid), "queue:#{@queue}") }
  ensure
    super
  end

  # Only the middleware under test, so a state write is unambiguously its own.
  # `config` doubles as the pool source (Middleware::ServerMiddleware#redis_pool
  # → config.redis_pool), which is also how a CommandSpy gets in front of it.
  def chain(config = Wurk.configuration.default_capsule)
    Wurk::Middleware::Chain.new(config) { |c| c.add(Wurk::Middleware::Status) }
  end

  def job(track: true, **extra)
    { 'class' => 'StatusMiddlewareJob', 'args' => [], 'jid' => @jid,
      'queue' => @queue, 'track' => track }.merge(extra).tap { |j| j.delete('track') if track.nil? }
  end

  def row = Wurk::Status.get(@jid)

  def hgetall
    raw = Wurk.redis { |c| c.call('HGETALL', Wurk::Status.key(@jid)) }
    raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
  end

  # A worker that can take the progress handle, like a real Wurk::Worker.
  class Worker
    attr_accessor :status
  end

  # --- the opt-in ----------------------------------------------------

  def test_an_untracked_job_writes_nothing
    assert_equal :ok, chain.invoke(Worker.new, job(track: nil), @queue) { :ok }
    assert_empty hgetall
  end

  def test_track_false_is_untracked
    chain.invoke(Worker.new, job(track: false), @queue) { :ok }

    assert_empty hgetall
  end

  def test_an_untracked_job_costs_no_redis_commands
    spy = Wurk::Test::CommandSpy.new(Wurk.redis_pool)
    chain(spy).invoke(Worker.new, job(track: nil), @queue) { :ok }

    assert_equal 0, spy.count, 'an untracked class must not reach Redis through this middleware'
  end

  # Two round trips for a whole tracked execution: one `running`, one terminal.
  def test_a_tracked_job_costs_one_write_per_state_transition
    spy = Wurk::Test::CommandSpy.new(Wurk.redis_pool)
    chain(spy).invoke(Worker.new, job, @queue) { :ok }

    assert_equal 2, spy.count
  end

  # A jid is the row's whole identity; without one there is nothing to write to.
  def test_a_tracked_job_without_a_jid_is_skipped
    assert_equal :ok, chain.invoke(Worker.new, job.merge('jid' => nil), @queue) { :ok }
    assert_equal :ok, chain.invoke(Worker.new, job.merge('jid' => ''), @queue) { :ok }
  end

  # --- running -------------------------------------------------------

  def test_running_is_visible_from_inside_perform
    seen = nil
    chain.invoke(Worker.new, job, @queue) { seen = Wurk::Status.get(@jid) }

    assert_equal 'running', seen.state
    assert_equal @queue, seen.queue
    assert_equal 'StatusMiddlewareJob', seen.job_class
    assert_operator seen.started_at, :>, 0
    assert_equal 1, seen.attempt
  end

  # `created_at` is epoch millis on the wire; the row keeps epoch seconds so
  # every timestamp on it compares directly.
  def test_enqueued_at_is_carried_from_the_payload_in_seconds
    chain.invoke(Worker.new, job('created_at' => 1_700_000_000_500), @queue) { :ok }

    assert_in_delta 1_700_000_000.5, row.enqueued_at
  end

  def test_enqueued_at_prefers_the_queue_stamp_over_creation
    chain.invoke(Worker.new, job('created_at' => 1_000, 'enqueued_at' => 2_000), @queue) { :ok }

    assert_in_delta 2.0, row.enqueued_at
  end

  # retry_count is stamped 0 on the FIRST failure, so the run after it is #2.
  def test_attempt_counts_executions_not_retries
    seen = []
    chain.invoke(Worker.new, job, @queue) { seen << Wurk::Status.get(@jid).attempt }
    chain.invoke(Worker.new, job('retry_count' => 0), @queue) { seen << Wurk::Status.get(@jid).attempt }
    chain.invoke(Worker.new, job('retry_count' => 3), @queue) { seen << Wurk::Status.get(@jid).attempt }

    assert_equal [1, 2, 5], seen
  end

  def test_every_write_stamps_a_ttl
    chain.invoke(Worker.new, job, @queue) do
      assert_operator Wurk.redis { |c| c.call('TTL', Wurk::Status.key(@jid)) }.to_i, :>, 0
    end

    assert_operator Wurk.redis { |c| c.call('TTL', Wurk::Status.key(@jid)) }.to_i, :>, 0
  end

  # --- complete + result capture -------------------------------------

  def test_a_clean_return_completes_and_stores_the_result
    assert_equal({ 'rows' => 7 }, chain.invoke(Worker.new, job, @queue) { { 'rows' => 7 } })

    assert_equal 'complete', row.state
    assert_equal({ 'rows' => 7 }, row.result)
    refute_predicate row, :result_truncated?
    assert_operator row.finished_at, :>=, row.started_at
  end

  def test_a_nil_result_is_not_stored
    chain.invoke(Worker.new, job, @queue) { nil }

    assert_equal 'complete', row.state
    assert_nil row.result
    refute_includes hgetall, 'result'
  end

  def test_scalar_results_round_trip
    chain.invoke(Worker.new, job, @queue) { 'done' }

    assert_equal 'done', row.result
  end

  def test_a_result_over_the_cap_is_truncated_with_a_flag
    big = 'x' * (Wurk::Middleware::Status::MAX_RESULT_BYTES * 2)
    chain.invoke(Worker.new, job, @queue) { big }

    assert_equal 'complete', row.state
    assert_predicate row, :result_truncated?
    assert_equal Wurk::Middleware::Status::MAX_RESULT_BYTES, hgetall['result'].bytesize
    assert row.result.start_with?('"xxx'), 'the head of the serialized value is kept'
  end

  # Cutting a byte budget can land mid-character; the row must still hold valid
  # UTF-8 rather than a dangling continuation byte.
  def test_a_truncated_multibyte_result_stays_valid_utf8
    chain.invoke(Worker.new, job, @queue) { 'é' * Wurk::Middleware::Status::MAX_RESULT_BYTES }

    assert_predicate hgetall['result'], :valid_encoding?
    assert_predicate row, :result_truncated?
  end

  # A result is a record of the job, never a reason to fail it.
  def test_a_result_that_refuses_to_serialize_does_not_fail_the_job
    unserializable = Object.new
    def unserializable.to_json(*) = raise(JSON::GeneratorError, 'nope')

    assert_same unserializable, chain.invoke(Worker.new, job, @queue) { unserializable }
    assert_equal 'complete', row.state
    assert_nil row.result
  end

  # --- interrupted / skipped are not failures ------------------------

  def test_a_cooperative_interruption_is_interrupted_not_failed
    assert_raises(Wurk::Job::Interrupted) do
      chain.invoke(Worker.new, job, @queue) { raise Wurk::Job::Interrupted }
    end

    assert_equal 'interrupted', row.state
    assert_nil row.error_class
  end

  def test_a_handled_skip_leaves_the_row_running
    assert_raises(Wurk::JobRetry::Skip) do
      chain.invoke(Worker.new, job, @queue) { raise Wurk::JobRetry::Skip }
    end

    assert_equal 'running', row.state, 'a re-queued job has not concluded — it will run again'
    assert_nil row.error_class
  end

  def test_a_handled_skip_still_persists_the_last_reported_progress
    worker = Worker.new
    assert_raises(Wurk::JobRetry::Skip) do
      chain.invoke(worker, job, @queue) do
        worker.status.at(1, 10)
        worker.status.at(4, 10, 'partway')
        raise Wurk::JobRetry::Skip
      end
    end

    assert_equal 4, row.progress
    assert_equal 'partway', row.message
  end

  # --- failed --------------------------------------------------------

  def test_a_raise_fails_the_row_and_records_the_error
    assert_raises(RuntimeError) { chain.invoke(Worker.new, job, @queue) { raise 'boom' } }

    assert_equal 'failed', row.state
    assert_equal 'RuntimeError', row.error_class
    assert_equal 'boom', row.error_message
    assert_operator row.finished_at, :>, 0
  end

  def test_an_oversized_error_message_is_capped
    assert_raises(RuntimeError) do
      chain.invoke(Worker.new, job, @queue) { raise 'y' * (Wurk::Middleware::Status::MAX_ERROR_BYTES * 3) }
    end

    assert_equal Wurk::Middleware::Status::MAX_ERROR_BYTES, hgetall['error_message'].bytesize
  end

  # --- the progress handle -------------------------------------------

  def test_the_worker_gets_a_progress_handle_for_a_tracked_job
    worker = Worker.new
    chain.invoke(worker, job, @queue) do
      assert_instance_of Wurk::Status::Progress, worker.status
      worker.status.at(3, 9, 'importing')
    end

    assert_equal 3, row.progress
    assert_equal 9, row.total
    assert_equal 'importing', row.message
  end

  def test_an_untracked_worker_gets_no_handle
    worker = Worker.new
    chain.invoke(worker, job(track: nil), @queue) { :ok }

    assert_nil worker.status
  end

  # Coalescing drops intermediate values; the terminal write must carry the
  # last one, and must not cost a round trip of its own to do it.
  def test_the_terminal_write_carries_the_last_coalesced_progress
    worker = Worker.new
    spy = Wurk::Test::CommandSpy.new(Wurk.redis_pool)
    chain(spy).invoke(worker, job, @queue) do
      worker.status.at(1, 100)          # first report, written immediately
      worker.status.at(99, 100, 'last') # inside the coalescing window
      :ok
    end

    assert_equal 99, row.progress
    assert_equal 'last', row.message
    assert_equal 'complete', row.state
    assert_equal 3, spy.count, 'running + first progress + one terminal write carrying the rest'
  end

  # A chain invoked with something that can't hold a handle (an ActiveJob
  # wrapper, nil in a direct test) still gets a full lifecycle.
  def test_a_worker_that_cannot_hold_a_handle_still_gets_a_lifecycle
    chain.invoke(nil, job, @queue) { :ok }

    assert_equal 'complete', row.state
  end

  # --- retrying / dead, written from JobRetry ------------------------

  def test_a_scheduled_retry_moves_the_row_to_retrying
    retrier = Wurk::JobRetry.new(Wurk.configuration.default_capsule)
    payload = Wurk.dump_json(job('retry' => 3, 'class' => 'StatusMiddlewareRetryJob'))

    assert_raises(Wurk::JobRetry::Handled) do
      retrier.global(payload, @queue) do
        chain.invoke(Worker.new, Wurk.load_json(payload), @queue) { raise 'transient' }
      end
    end

    assert_equal 'retrying', row.state
    assert_equal 'RuntimeError', row.error_class
    assert_equal 'transient', row.error_message
    assert_equal 1, row.attempt
  ensure
    Wurk.redis { |c| c.call('ZREM', Wurk::Keys::RETRY, *Wurk.redis { |x| x.call('ZRANGE', Wurk::Keys::RETRY, 0, -1) }) }
  end

  def test_an_exhausted_job_moves_the_row_to_dead
    retrier = Wurk::JobRetry.new(Wurk.configuration.default_capsule)
    payload = Wurk.dump_json(job('retry' => 0, 'dead' => false,
                                 'class' => 'StatusMiddlewareDeadJob'))

    assert_raises(Wurk::JobRetry::Handled) do
      retrier.global(payload, @queue) do
        chain.invoke(Worker.new, Wurk.load_json(payload), @queue) { raise 'fatal' }
      end
    end

    assert_equal 'dead', row.state
    assert_equal 'RuntimeError', row.error_class
    assert_equal 'fatal', row.error_message
  end

  def test_the_death_handler_ignores_an_untracked_job
    Wurk::Middleware::Status::DeathHandler.call(job(track: nil).merge('error_class' => 'X'), nil)

    assert_empty hgetall
  end

  def test_the_death_handler_ignores_a_job_with_no_jid
    Wurk::Middleware::Status::DeathHandler.call(job.merge('jid' => nil), nil)
    Wurk::Middleware::Status::DeathHandler.call(job.merge('jid' => ''), nil)

    assert_empty hgetall
  end

  # Death handlers run in a chain; a payload this one cannot make sense of must
  # cost the job its `dead` row, not take the rest of the chain down.
  def test_the_death_handler_swallows_a_payload_it_cannot_write
    hostile = Object.new
    def hostile.to_s = raise('not a string')

    Wurk::Middleware::Status::DeathHandler.call(job.merge('error_message' => hostile), nil)

    assert_empty hgetall
  end

  def test_the_death_handler_is_registered
    assert_includes Wurk.configuration.death_handlers, Wurk::Middleware::Status::DeathHandler
  end

  # --- chain position ------------------------------------------------

  # Last of the built-ins, so the stored result is `perform`'s own return value
  # and nothing wraps or replaces it first. Asserted relatively, not as
  # `entries.last`: a host (or another test file requiring an optional
  # middleware) may `add` after boot and land further in still.
  def test_status_is_the_innermost_built_in_middleware
    entries = Wurk.configuration.server_middleware.entries.map(&:klass)
    mine = entries.index(Wurk::Middleware::Status)

    refute_nil mine, 'Middleware::Status must be auto-registered'
    [Wurk::Middleware::InterruptHandler, Wurk::Batch::ServerMiddleware, Wurk::Middleware::Expiry,
     Wurk::Limiter::ServerMiddleware, Wurk::Metrics::Statsd, Wurk::Metrics::History].each do |outer|
      assert_operator entries.index(outer), :<, mine, "#{outer} must be OUTER of Middleware::Status"
    end
  end

  # --- a status write must never break the job -----------------------

  # A dead pool rather than a stubbed Status.write: these tests run alongside
  # others in the same process, and a global stub would break theirs too.
  class DeadPool
    def with(*) = raise('redis down')
  end

  class DeadConfig
    def redis_pool = DeadPool.new
  end

  def dead_chain
    Wurk::Middleware::Chain.new(DeadConfig.new) { |c| c.add(Wurk::Middleware::Status) }
  end

  def test_a_redis_failure_while_writing_status_does_not_fail_the_job
    assert_equal :ok, dead_chain.invoke(Worker.new, job, @queue) { :ok }
    assert_empty hgetall
  end

  def test_a_redis_failure_while_writing_status_does_not_mask_the_job_error
    error = assert_raises(ArgumentError) do
      dead_chain.invoke(Worker.new, job, @queue) do
        raise ArgumentError, 'original'
      end
    end

    assert_equal 'original', error.message
  end
end
