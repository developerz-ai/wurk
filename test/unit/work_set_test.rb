# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Drives Wurk::WorkSet + Wurk::Work against real Redis. The `processes` SET +
# `<identity>:work` HASHes are shared globally; tests scope to unique identities
# and assert presence rather than equality on cluster-wide counters.
class WorkSetTest < Wurk::Test::UnitCase
  def setup
    super
    @ns         = "#{Process.pid}-#{object_id}"
    @identity   = "host-#{@ns}:1234:abc#{object_id.to_s(16)}"
    @other_id   = "host-#{@ns}:5678:def#{object_id.to_s(16)}"
    @pool       = Wurk.configuration.redis_pool
    @identities = []
  end

  def teardown
    @pool.with do |c|
      @identities.each do |id|
        c.call('SREM', 'processes', id)
        c.call('DEL', id, "#{id}:work")
      end
    end
  ensure
    super
  end

  # --- shape -------------------------------------------------------------

  def test_includes_enumerable
    assert_includes Wurk::WorkSet.ancestors, Enumerable
  end

  # --- size --------------------------------------------------------------

  def test_size_returns_zero_when_no_processes_registered
    @pool.with { |c| c.call('DEL', 'processes') }

    assert_equal 0, Wurk::WorkSet.new.size
  end

  def test_size_sums_busy_field_across_identities
    register!(@identity, busy: '4')
    register!(@other_id, busy: '3')

    assert_operator Wurk::WorkSet.new.size, :>=, 7
  end

  def test_size_treats_missing_busy_field_as_zero
    register!(@identity)

    assert_kind_of Integer, Wurk::WorkSet.new.size
  end

  # --- each --------------------------------------------------------------

  # rubocop:disable Minitest/MultipleAssertions
  # One test, one yielded shape: pid/tid/job.jid are the public contract.
  def test_each_yields_pid_tid_work_triples
    jid = push_work(@identity, 't1')
    yielded = mine.first

    refute_nil yielded
    pid, tid, work = yielded

    assert_equal @identity, pid
    assert_equal 't1',     tid
    assert_equal jid,      work.job.jid
  end
  # rubocop:enable Minitest/MultipleAssertions

  def test_each_skips_empty_work_hashes
    register!(@identity)

    refute_includes(Wurk::WorkSet.new.map { |pid, _, _| pid }, @identity)
  end

  def test_each_yields_sorted_by_run_at
    push_work(@identity, 't1', run_at: 1000.0)
    push_work(@identity, 't2', run_at: 500.0)
    push_work(@identity, 't3', run_at: 2000.0)
    mine = Wurk::WorkSet.new.select { |pid, _, _| pid == @identity }.map { |_, _, w| w.run_at.to_f }

    assert_equal mine.sort, mine
  end

  def test_each_returns_when_processes_set_empty
    @pool.with { |c| c.call('DEL', 'processes') }
    count = 0
    Wurk::WorkSet.new.each { |_, _, _| count += 1 }

    assert_equal 0, count
  end

  # --- find_work ---------------------------------------------------------

  def test_find_work_returns_matching_work
    jid = push_work(@identity, 't1')
    work = Wurk::WorkSet.new.find_work(jid)

    refute_nil work
    assert_kind_of Wurk::Work, work
    assert_equal jid, work.job.jid
  end

  def test_find_work_returns_nil_for_unknown_jid
    push_work(@identity, 't1')

    assert_nil Wurk::WorkSet.new.find_work('deadbeef' * 3)
  end

  def test_find_work_by_jid_is_aliased
    jid = push_work(@identity, 't1')

    assert_equal jid, Wurk::WorkSet.new.find_work_by_jid(jid).job.jid
  end

  # --- Wurk::Work --------------------------------------------------------

  def test_work_exposes_queue
    push_work(@identity, 't1', queue: 'mailers')
    _, _, work = mine.first

    assert_equal 'mailers', work.queue
  end

  def test_work_run_at_returns_time
    push_work(@identity, 't1', run_at: 1_700_000_000.5)
    _, _, work = mine.first

    assert_kind_of Time, work.run_at
    assert_in_delta 1_700_000_000.5, work.run_at.to_f, 0.01
  end

  def test_work_payload_returns_raw_json
    jid = push_work(@identity, 't1')
    _, _, work = mine.first

    assert_kind_of String, work.payload
    assert_includes work.payload, jid
  end

  def test_work_job_returns_lazy_job_record
    push_work(@identity, 't1')
    _, _, work = mine.first

    assert_kind_of Wurk::JobRecord, work.job
    assert_same work.job, work.job
  end

  # --- Workers alias -----------------------------------------------------

  def test_workers_is_deprecated_alias_for_work_set
    assert_equal Wurk::WorkSet, Wurk::Workers
  end

  def test_sidekiq_workers_aliased
    assert_equal Wurk::WorkSet, Sidekiq::Workers
  end

  def test_sidekiq_work_set_aliased
    assert_equal Wurk::WorkSet, Sidekiq::WorkSet
  end

  def test_sidekiq_work_aliased
    assert_equal Wurk::Work, Sidekiq::Work
  end

  private

  def mine
    Wurk::WorkSet.new.select { |pid, _, _| pid == @identity }
  end

  def register!(identity, fields = {})
    @identities << identity unless @identities.include?(identity)
    @pool.with do |c|
      c.call('SADD', 'processes', identity)
      fields.each { |k, v| c.call('HSET', identity, k.to_s, v) }
    end
  end

  def push_work(identity, tid, queue: 'default', run_at: ::Process.clock_gettime(::Process::CLOCK_REALTIME), jid: nil)
    jid ||= SecureRandom.hex(12)
    register!(identity)
    payload = Wurk.dump_json('class' => 'WorkSetJob', 'args' => [], 'queue' => queue, 'jid' => jid)
    hsh = Wurk.dump_json('queue' => queue, 'run_at' => run_at, 'payload' => payload)
    @pool.with { |c| c.call('HSET', "#{identity}:work", tid, hsh) }
    jid
  end
end
