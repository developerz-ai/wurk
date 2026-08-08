# frozen_string_literal: true

require 'delegate'
require_relative '../test_helper'

# Wurk::Status core: the `status:<jid>` row, its Lua write, the typed read view,
# and the coalescing progress handle. The server middleware that drives the
# lifecycle is a separate layer and is tested separately.
class StatusTest < Wurk::Test::UnitCase
  parallelize_me!

  # EVALSHA counts as one command only against a warm script cache; a cold one
  # pays NOSCRIPT + SCRIPT LOAD + retry and the round-trip assertions below
  # would read three.
  def setup
    super
    Wurk.redis { |conn| Wurk::Lua::Loader.script_load_all(conn) }
  end

  def jid(suffix = 'a') = "#{Process.pid}#{object_id}#{suffix}"

  def hgetall(key)
    raw = Wurk.redis { |c| c.call('HGETALL', key) }
    raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
  end

  def ttl(key) = Wurk.redis { |c| c.call('TTL', key) }.to_i

  # --- keys ----------------------------------------------------------

  def test_key_is_namespaced_under_status_prefix
    assert_equal 'status:abc123', Wurk::Status.key('abc123')
    assert_equal 'status:abc123', Wurk::Keys.status('abc123')
  end

  # The sidekiq-status gem stores `sidekiq:status:<jid>`. A host running both
  # must end up with two independent rows, never one they overwrite for each
  # other — this is the whole coexistence contract for the slice.
  def test_key_does_not_collide_with_sidekiq_status_gem
    refute_equal 'sidekiq:status:abc123', Wurk::Status.key('abc123')
    refute_operator Wurk::Status.key('abc123'), :start_with?, 'sidekiq:'
  end

  # --- write ---------------------------------------------------------

  def test_write_creates_row_with_ttl_in_one_round_trip
    id = jid
    spy = Wurk::Test::CommandSpy.new(Wurk.redis_pool)
    Thread.current[:wurk_capsule] = spy
    Wurk::Status.write(id, state: 'enqueued', queue: 'default', class: 'MyJob')
    Thread.current[:wurk_capsule] = nil

    assert_equal 1, spy.count, 'HSET + EXPIRE must be one EVALSHA, not two commands'
    assert_equal({ 'state' => 'enqueued', 'queue' => 'default', 'class' => 'MyJob' },
                 hgetall(Wurk::Status.key(id)))
    assert_operator ttl(Wurk::Status.key(id)), :>, 0
  ensure
    Thread.current[:wurk_capsule] = nil
  end

  def test_write_honours_explicit_ttl
    id = jid
    Wurk::Status.write(id, ttl: 90, state: 'running')

    assert_operator ttl(Wurk::Status.key(id)), :<=, 90
    assert_operator ttl(Wurk::Status.key(id)), :>, 0
  end

  def test_write_restamps_ttl_on_every_write
    id = jid
    Wurk::Status.write(id, ttl: 10, state: 'enqueued')
    Wurk::Status.write(id, ttl: 600, state: 'running')

    assert_operator ttl(Wurk::Status.key(id)), :>, 10
  end

  def test_write_merges_fields_rather_than_replacing_the_row
    id = jid
    Wurk::Status.write(id, state: 'enqueued', queue: 'default')
    Wurk::Status.write(id, state: 'running', started_at: 1.5)

    assert_equal({ 'state' => 'running', 'queue' => 'default', 'started_at' => '1.5' },
                 hgetall(Wurk::Status.key(id)))
  end

  def test_write_drops_nil_fields
    id = jid
    Wurk::Status.write(id, state: 'running', message: nil, total: nil)

    assert_equal({ 'state' => 'running' }, hgetall(Wurk::Status.key(id)))
  end

  def test_write_with_only_nil_fields_touches_nothing
    id = jid

    refute Wurk::Status.write(id, message: nil)
    assert_empty hgetall(Wurk::Status.key(id))
  end

  def test_write_rejects_an_unknown_state
    error = assert_raises(ArgumentError) { Wurk::Status.write(jid, state: 'finished') }

    assert_match(/unknown status state/, error.message)
  end

  def test_write_accepts_every_declared_state
    id = jid

    Wurk::Status::STATES.each do |state|
      assert Wurk::Status.write(id, state: state), "#{state} must be writable"
    end
  end

  # --- create gate ---------------------------------------------------

  def test_write_without_create_does_not_conjure_a_row
    id = jid

    refute Wurk::Status.write(id, create: false, progress: 10)
    assert_empty hgetall(Wurk::Status.key(id)),
                 'a progress write must never resurrect an expired/deleted row as a stateless phantom'
  end

  def test_write_without_create_updates_a_live_row
    id = jid
    Wurk::Status.write(id, state: 'running')

    assert Wurk::Status.write(id, create: false, progress: 10, total: 100)
    assert_equal({ 'state' => 'running', 'progress' => '10', 'total' => '100' },
                 hgetall(Wurk::Status.key(id)))
  end

  # --- get -----------------------------------------------------------

  def test_get_returns_nil_for_an_unknown_jid
    assert_nil Wurk::Status.get(jid)
  end

  def test_get_returns_a_typed_record
    id = jid
    Wurk::Status.write(id, state: 'complete', queue: 'critical', class: 'MyJob',
                           enqueued_at: 1.5, started_at: 2.5, finished_at: 3.75,
                           progress: 100, total: 100, message: 'done', attempt: 2,
                           result: JSON.generate({ 'rows' => 7 }))
    record = Wurk::Status.get(id)

    assert_equal id, record.jid
    assert_equal 'complete', record.state
    assert_equal 'critical', record.queue
    assert_equal 'MyJob', record.job_class
    assert_in_delta 1.5, record.enqueued_at
    assert_in_delta 2.5, record.started_at
    assert_in_delta 3.75, record.finished_at
    assert_equal 100, record.progress
    assert_equal 100, record.total
    assert_equal 2, record.attempt
    assert_equal 'done', record.message
    assert_equal({ 'rows' => 7 }, record.result)
  end

  def test_get_reads_error_fields
    id = jid
    Wurk::Status.write(id, state: 'failed', error_class: 'RuntimeError', error_message: 'boom')
    record = Wurk::Status.get(id)

    assert_equal 'RuntimeError', record.error_class
    assert_equal 'boom', record.error_message
  end

  # Unset is not zero: a job that never reported progress must not read as
  # "at 0 of 0", which a dashboard would render as a real position.
  def test_record_reports_unset_numeric_fields_as_nil
    id = jid
    Wurk::Status.write(id, state: 'enqueued')
    record = Wurk::Status.get(id)

    assert_nil record.progress
    assert_nil record.total
    assert_nil record.attempt
    assert_nil record.enqueued_at
    assert_nil record.result
  end

  def test_record_exposes_raw_fields_by_wire_name
    id = jid
    Wurk::Status.write(id, state: 'running', class: 'MyJob')
    record = Wurk::Status.get(id)

    assert_equal 'MyJob', record['class']
    assert_equal 'running', record[:state]
  end

  def test_record_to_h_uses_wire_field_names
    id = jid
    Wurk::Status.write(id, state: 'complete', class: 'MyJob', progress: 3,
                           result: JSON.generate([1, 2]))

    assert_equal({ 'jid' => id, 'state' => 'complete', 'queue' => nil, 'class' => 'MyJob',
                   'enqueued_at' => nil, 'started_at' => nil, 'finished_at' => nil,
                   'progress' => 3, 'total' => nil, 'message' => nil, 'result' => [1, 2],
                   'result_truncated' => false, 'error_class' => nil, 'error_message' => nil,
                   'attempt' => nil },
                 Wurk::Status.get(id).to_h)
  end

  # --- delete --------------------------------------------------------

  def test_delete_removes_the_row
    id = jid
    Wurk::Status.write(id, state: 'complete')

    assert Wurk::Status.delete(id)
    assert_nil Wurk::Status.get(id)
  end

  def test_delete_reports_false_when_there_was_nothing_to_delete
    refute Wurk::Status.delete(jid)
  end

  # --- explicit pool -------------------------------------------------

  # Forked workers write through their own capsule pool, so every entry point
  # takes `pool:` rather than reaching for the global.
  def test_accepts_an_explicit_pool
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, timeout: 2, name: 'status-test')
    id = jid
    Wurk::Status.write(id, pool: pool, state: 'running')

    assert_equal 'running', Wurk::Status.get(id, pool: pool).state
    assert Wurk::Status.delete(id, pool: pool)
  ensure
    pool&.disconnect!
  end

  # A host may hand any ConnectionPool-shaped object to `pool:`, and redis-client
  # returns HGETALL as a flat array (RESP2) or nil on some adapters where it
  # returns a Hash here. Real Redis underneath, real values — only the reply
  # shape is reshaped, which is exactly what a foreign adapter does.
  class ShapeShiftingPool
    def initialize(pool, shape)
      @pool = pool
      @shape = shape
    end

    def with(...) = @pool.with { |conn| yield Tap.new(conn, @shape) }

    class Tap < SimpleDelegator
      def initialize(conn, shape)
        super(conn)
        @shape = shape
      end

      def call(*args)
        reply = __getobj__.call(*args)
        return reply unless args.first == 'HGETALL'

        @shape == :array ? reply.to_a.flatten : nil
      end
    end
  end

  def test_get_normalizes_a_flat_array_reply
    id = jid
    Wurk::Status.write(id, state: 'running', progress: 5)
    pool = ShapeShiftingPool.new(Wurk.redis_pool, :array)

    assert_equal 5, Wurk::Status.get(id, pool: pool).progress
  end

  def test_get_returns_nil_for_an_unrecognized_reply_shape
    id = jid
    Wurk::Status.write(id, state: 'running')

    assert_nil Wurk::Status.get(id, pool: ShapeShiftingPool.new(Wurk.redis_pool, :nil))
  end

  # --- progress coalescing -------------------------------------------

  def test_progress_first_report_is_written_immediately
    id = jid
    Wurk::Status.write(id, state: 'running')
    Wurk::Status::Progress.new(id).at(1, 100, 'starting')

    assert_equal({ 'state' => 'running', 'progress' => '1', 'total' => '100', 'message' => 'starting' },
                 hgetall(Wurk::Status.key(id)))
  end

  def test_progress_coalesces_a_tight_loop_into_one_write
    id = jid
    Wurk::Status.write(id, state: 'running')
    handle = Wurk::Status::Progress.new(id)
    spy = Wurk::Test::CommandSpy.new(Wurk.redis_pool)
    Thread.current[:wurk_capsule] = spy
    1_000.times { |i| handle.at(i, 1_000) }
    Thread.current[:wurk_capsule] = nil

    assert_equal 1, spy.count, '1000 at() calls inside one interval must cost one write'
    assert_equal '0', hgetall(Wurk::Status.key(id))['progress']
  ensure
    Thread.current[:wurk_capsule] = nil
  end

  def test_progress_writes_again_once_the_interval_elapses
    id = jid
    Wurk::Status.write(id, state: 'running')
    handle = Wurk::Status::Progress.new(id, interval: 0)
    handle.at(1)
    handle.at(2)

    assert_equal '2', hgetall(Wurk::Status.key(id))['progress']
  end

  # Coalescing may drop intermediate values; it must never drop the last one.
  def test_progress_flush_persists_the_newest_buffered_values
    id = jid
    Wurk::Status.write(id, state: 'running')
    handle = Wurk::Status::Progress.new(id)
    handle.at(1, 10)
    handle.at(7, 10, 'nearly there')

    assert_equal '1', hgetall(Wurk::Status.key(id))['progress'], 'second at() is inside the window'
    assert handle.flush
    assert_equal({ 'state' => 'running', 'progress' => '7', 'total' => '10', 'message' => 'nearly there' },
                 hgetall(Wurk::Status.key(id)))
  end

  def test_progress_flush_is_a_noop_with_nothing_buffered
    id = jid
    Wurk::Status.write(id, state: 'running')
    handle = Wurk::Status::Progress.new(id)
    handle.at(1)

    refute handle.flush
  end

  def test_progress_keeps_total_and_message_sticky
    id = jid
    Wurk::Status.write(id, state: 'running')
    handle = Wurk::Status::Progress.new(id, interval: 0)
    handle.at(1, 50, 'importing')
    handle.at(2)

    assert_equal({ 'state' => 'running', 'progress' => '2', 'total' => '50', 'message' => 'importing' },
                 hgetall(Wurk::Status.key(id)))
  end

  def test_progress_message_reports_without_moving_the_counter
    id = jid
    Wurk::Status.write(id, state: 'running')
    handle = Wurk::Status::Progress.new(id, interval: 0)
    handle.at(4, 10)
    handle.message('flushing')

    assert_equal '4', hgetall(Wurk::Status.key(id))['progress']
    assert_equal 'flushing', hgetall(Wurk::Status.key(id))['message']
  end

  def test_progress_at_returns_its_argument
    id = jid
    Wurk::Status.write(id, state: 'running')

    assert_equal 42, Wurk::Status::Progress.new(id).at(42)
  end

  def test_progress_never_creates_a_row_for_a_finished_job
    id = jid
    handle = Wurk::Status::Progress.new(id, interval: 0)
    handle.at(1, 100)
    handle.message('still going')

    assert_empty hgetall(Wurk::Status.key(id))
  end

  # A dropped write is discarded, not queued: the next attempt of the same jid
  # creates a fresh row, and progress from the abandoned run must not leak into
  # it.
  def test_progress_dropped_by_the_create_gate_is_not_replayed_into_a_later_row
    id = jid
    handle = Wurk::Status::Progress.new(id, interval: 0)
    handle.at(9, 100, 'stale')
    Wurk::Status.write(id, state: 'running')

    refute handle.flush
    assert_equal({ 'state' => 'running' }, hgetall(Wurk::Status.key(id)))
  end

  def test_progress_refreshes_the_row_ttl
    id = jid
    Wurk::Status.write(id, ttl: 10, state: 'running')
    Wurk::Status::Progress.new(id, ttl: 600).at(1)

    assert_operator ttl(Wurk::Status.key(id)), :>, 10
  end

  def test_progress_accepts_an_explicit_pool
    pool = Wurk::RedisPool.new(size: 1, url: Wurk::Test.redis_url, timeout: 2, name: 'status-progress')
    id = jid
    Wurk::Status.write(id, pool: pool, state: 'running')
    Wurk::Status::Progress.new(id, pool: pool).at(3)

    assert_equal 3, Wurk::Status.get(id, pool: pool).progress
  ensure
    pool&.disconnect!
  end
end
