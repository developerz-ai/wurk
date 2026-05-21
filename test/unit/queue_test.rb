# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Drives Wurk::Queue against real Redis. The queues set is shared globally;
# tests use per-instance queue names to stay safe under across-file
# parallelism, and assert lower bounds where the shared `queues` set is
# observed.
class QueueTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns      = "#{Process.pid}-#{object_id}"
    @qname   = "queue-q-#{@ns}"
    @rqname  = "queue:#{@qname}"
    @pool    = Wurk.configuration.redis_pool
    @pool.with do |c|
      c.call('DEL', @rqname)
      c.call('SREM', 'queues', @qname)
    end
  end

  def teardown
    @pool.with do |c|
      c.call('DEL', @rqname)
      c.call('SREM', 'queues', @qname)
    end
  ensure
    super
  end

  # --- shape -------------------------------------------------------------

  def test_default_name_is_default
    assert_equal 'default', Wurk::Queue.new.name
  end

  def test_name_coerces_to_string
    assert_equal 'mailers', Wurk::Queue.new(:mailers).name
  end

  def test_id_aliases_name
    q = Wurk::Queue.new(@qname)

    assert_equal q.name, q.id
  end

  def test_includes_enumerable
    assert_includes Wurk::Queue.ancestors, Enumerable
  end

  def test_paused_is_false_by_default
    refute_predicate Wurk::Queue.new(@qname), :paused?
  end

  def test_as_json_returns_name_only
    assert_equal({ name: @qname }, Wurk::Queue.new(@qname).as_json)
  end

  # --- size / latency ----------------------------------------------------

  def test_size_is_zero_for_empty_queue
    assert_equal 0, Wurk::Queue.new(@qname).size
  end

  def test_size_reflects_llen
    push_job
    push_job

    assert_equal 2, Wurk::Queue.new(@qname).size
  end

  def test_latency_is_zero_for_empty_queue
    assert_in_delta(0.0, Wurk::Queue.new(@qname).latency)
  end

  def test_latency_uses_tail_enqueued_at_ms
    push_job(enqueued_at: ms_now - 4_000)

    assert_in_delta 4.0, Wurk::Queue.new(@qname).latency, 1.5
  end

  def test_latency_handles_legacy_float_seconds
    push_job(enqueued_at: (ms_now - 2_500) / 1000.0)

    assert_in_delta 2.5, Wurk::Queue.new(@qname).latency, 1.5
  end

  def test_latency_swallows_malformed_payload
    @pool.with do |c|
      c.call('SADD', 'queues', @qname)
      c.call('LPUSH', @rqname, 'not json{{')
    end

    assert_in_delta(0.0, Wurk::Queue.new(@qname).latency)
  end

  # --- iteration ---------------------------------------------------------

  def test_each_yields_job_records
    push_job
    records = Wurk::Queue.new(@qname).to_a

    assert_equal 1, records.size
    assert_kind_of Wurk::JobRecord, records.first
  end

  def test_each_assigns_queue_name_to_records
    push_job
    record = Wurk::Queue.new(@qname).first

    assert_equal @qname, record.queue
  end

  def test_each_pages_past_page_size
    total = Wurk::Queue::PAGE_SIZE + 5
    total.times { push_job }

    assert_equal total, Wurk::Queue.new(@qname).count
  end

  # --- find_job ----------------------------------------------------------

  def test_find_job_returns_record_for_known_jid
    jid = push_job
    record = Wurk::Queue.new(@qname).find_job(jid)

    refute_nil record
    assert_equal jid, record.jid
  end

  def test_find_job_returns_nil_for_unknown_jid
    push_job

    assert_nil Wurk::Queue.new(@qname).find_job('deadbeef' * 3)
  end

  # --- clear -------------------------------------------------------------

  def test_clear_returns_true_and_empties_queue
    push_job

    assert Wurk::Queue.new(@qname).clear
    assert_equal(0, @pool.with { |c| c.call('LLEN', @rqname) })
  end

  def test_clear_removes_queue_from_queues_set
    push_job
    Wurk::Queue.new(@qname).clear

    refute_includes @pool.with { |c| c.call('SMEMBERS', 'queues') }, @qname
  end

  # --- all ---------------------------------------------------------------

  def test_all_returns_queue_instances
    push_job
    names = Wurk::Queue.all.map(&:name)

    assert_includes names, @qname
  end

  def test_all_is_sorted_by_name
    push_job
    names = Wurk::Queue.all.map(&:name)

    assert_equal names.sort, names
  end

  private

  def push_job(enqueued_at: ms_now)
    jid = SecureRandom.hex(12)
    payload = Wurk.dump_json(
      'class' => 'QueueTestJob',
      'args' => [],
      'queue' => @qname,
      'jid' => jid,
      'enqueued_at' => enqueued_at
    )
    @pool.with do |c|
      c.call('SADD', 'queues', @qname)
      c.call('LPUSH', @rqname, payload)
    end
    jid
  end

  def ms_now
    ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
  end
end
