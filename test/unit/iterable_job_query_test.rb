# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Drives Wurk::IterableJobQuery (Sidekiq::IterableJobQuery) + JobRecord#iterable_state
# against real Redis. Writes `it-<jid>` HASHes directly (the wire format the
# IterableJob runtime produces — ex/rt/c/cancelled, spec §1.5) and asserts the
# read-side data API decodes them. Issue #165 / spec §19.3 + §19.9.
#
# Parallel safety: every jid is scoped to PID:object_id and DEL'd in teardown.
class IterableJobQueryTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @pool = Wurk.configuration.redis_pool
    @jids = []
  end

  def teardown
    @pool.with { |c| @jids.uniq.each { |jid| c.call('DEL', "it-#{jid}") } }
  ensure
    super
  end

  # --- State decoding ----------------------------------------------------

  # One canonical State shape — all four decoded fields belong in one assertion set.
  def test_state_decodes_wire_fields
    jid = seed(ex: 3, rt: 12.5, cursor: [42, 'page'])
    state = Wurk::IterableJobQuery.new([jid])[jid]

    assert_equal jid, state.jid
    assert_equal 3, state.executions
    assert_in_delta 12.5, state.runtime
    assert_equal [42, 'page'], state.cursor
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_cancelled_is_nil_when_not_cancelled
    jid = seed(ex: 1, rt: 0.0, cursor: nil)

    assert_nil Wurk::IterableJobQuery.new([jid])[jid].cancelled
  end

  def test_cancelled_returns_timestamp_when_cancelled
    jid = seed(ex: 1, rt: 0.0, cursor: nil, cancelled: 1_700_000_000)

    assert_equal 1_700_000_000, Wurk::IterableJobQuery.new([jid])[jid].cancelled
  end

  def test_cursor_is_nil_when_absent
    jid = next_jid
    @pool.with { |c| c.call('HSET', "it-#{jid}", 'ex', '1', 'rt', '0.0') }

    assert_nil Wurk::IterableJobQuery.new([jid])[jid].cursor
  end

  # --- lookup / nil semantics -------------------------------------------

  def test_index_returns_nil_for_unknown_jid
    assert_nil Wurk::IterableJobQuery.new([next_jid])[next_jid]
  end

  def test_index_returns_nil_for_jid_with_no_state
    assert_nil Wurk::IterableJobQuery.new([next_jid]).send(:[], 'never-seeded')
  end

  # --- bulk / enumeration ------------------------------------------------

  def test_bulk_query_reads_many_in_one_pass
    a = seed(ex: 1, rt: 1.0, cursor: nil)
    missing = next_jid
    b = seed(ex: 2, rt: 2.0, cursor: nil)
    query = Wurk::IterableJobQuery.new([a, missing, b])

    assert_equal 1, query[a].executions
    assert_equal 2, query[b].executions
    assert_nil query[missing]
  end

  def test_each_yields_only_present_states_in_order
    a = seed(ex: 1, rt: 0.0, cursor: nil)
    missing = next_jid
    b = seed(ex: 2, rt: 0.0, cursor: nil)

    yielded = Wurk::IterableJobQuery.new([a, missing, b]).map(&:jid)

    assert_equal [a, b], yielded
  end

  def test_empty_jids_yields_nothing
    query = Wurk::IterableJobQuery.new([])

    assert_empty query.to_a
  end

  # --- JobRecord#iterable_state -----------------------------------------

  def test_job_record_iterable_state_returns_state
    jid = seed(ex: 4, rt: 0.0, cursor: nil)
    record = Wurk::JobRecord.new({ 'class' => 'X', 'args' => [], 'jid' => jid, 'queue' => 'default' })

    assert_equal 4, record.iterable_state.executions
  end

  def test_job_record_iterable_state_nil_for_non_iterable_job
    record = Wurk::JobRecord.new({ 'class' => 'X', 'args' => [], 'jid' => next_jid, 'queue' => 'default' })

    assert_nil record.iterable_state
  end

  def test_job_record_iterable_state_nil_without_jid
    record = Wurk::JobRecord.new({ 'class' => 'X', 'args' => [], 'queue' => 'default' })

    assert_nil record.iterable_state
  end

  # --- Sidekiq drop-in alias --------------------------------------------

  def test_sidekiq_alias
    assert_same Wurk::IterableJobQuery, Sidekiq::IterableJobQuery
    assert_same Wurk::IterableJobQuery::State, Sidekiq::IterableJobQuery::State
  end

  private

  def next_jid
    @counter = (@counter || 0) + 1
    jid = "itq-#{Process.pid}-#{object_id}-#{@counter}"
    @jids << jid
    jid
  end

  # Writes an it-<jid> HASH in the runtime's wire format (ex/rt/c/cancelled,
  # spec §1.5). Param names mirror the wire fields. Returns the jid.
  def seed(ex:, rt:, cursor:, cancelled: nil) # rubocop:disable Naming/MethodParameterName
    jid = next_jid
    fields = ['ex', ex.to_s, 'rt', rt.to_s]
    fields += ['c', ::JSON.generate(cursor)] unless cursor.nil?
    fields += ['cancelled', cancelled.to_s] unless cancelled.nil?
    @pool.with { |c| c.call('HSET', "it-#{jid}", *fields) }
    jid
  end
end
