# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Lua-backed Pro fast API:
#   Queue#delete_job(jid)
#   Queue#delete_by_class(klass)
#   SortedSet#scan(pattern) { |SortedEntry| … }   # arity-1 form
#   SortedSet#scan(pattern) { |value, score| … }  # legacy arity-2 form (unchanged)
#
# Spec: docs/target/sidekiq-pro.md §11.
class APIFastTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns       = "#{Process.pid}-#{object_id}"
    @qname    = "fastq-#{@ns}"
    @rqname   = "queue:#{@qname}"
    @set_name = "retry-fast-#{@ns}"
    @set      = Wurk::RetrySet.new(@set_name)
    @pool     = Wurk.configuration.redis_pool
    clean
  end

  def teardown
    clean
  ensure
    super
  end

  # --- Queue#delete_job ---------------------------------------------------

  def test_delete_job_removes_matching_payload
    jid = push_job
    push_job

    removed = Wurk::Queue.new(@qname).delete_job(jid)

    assert_equal 1, removed
    assert_equal 1, queue_size
  end

  def test_delete_job_returns_zero_when_jid_absent
    push_job

    assert_equal 0, Wurk::Queue.new(@qname).delete_job(SecureRandom.hex(12))
    assert_equal 1, queue_size
  end

  def test_delete_job_raises_on_empty_jid
    assert_raises(ArgumentError) { Wurk::Queue.new(@qname).delete_job(nil) }
    assert_raises(ArgumentError) { Wurk::Queue.new(@qname).delete_job('') }
  end

  def test_delete_job_handles_empty_queue
    assert_equal 0, Wurk::Queue.new(@qname).delete_job(SecureRandom.hex(12))
  end

  # --- Queue#delete_by_class ---------------------------------------------

  def test_delete_by_class_removes_all_matching_payloads
    3.times { push_job(klass: 'TargetJob') }
    2.times { push_job(klass: 'OtherJob') }

    removed = Wurk::Queue.new(@qname).delete_by_class('TargetJob')

    assert_equal 3, removed
    assert_equal 2, queue_size
  end

  def test_delete_by_class_accepts_class_constant
    klass = Class.new
    Object.const_set("ApiFastJob_#{@ns.tr('-', '_')}", klass)
    push_job(klass: klass.name)

    assert_equal 1, Wurk::Queue.new(@qname).delete_by_class(klass)
  ensure
    name = "ApiFastJob_#{@ns.tr('-', '_')}"
    Object.send(:remove_const, name) if Object.const_defined?(name)
  end

  def test_delete_by_class_returns_zero_for_unknown_class
    push_job(klass: 'A')

    assert_equal 0, Wurk::Queue.new(@qname).delete_by_class('B')
    assert_equal 1, queue_size
  end

  def test_delete_by_class_raises_on_empty_input
    assert_raises(ArgumentError) { Wurk::Queue.new(@qname).delete_by_class('') }
  end

  # --- SortedSet#scan (arity-1 sorted entry form) ------------------------

  def test_scan_yields_sorted_entry_for_arity_one_block
    jid = SecureRandom.hex(12)
    add_member(jid: jid)
    yielded = []
    @set.scan(jid) { |entry| yielded << entry }

    assert_equal 1, yielded.size
    assert_kind_of Wurk::SortedEntry, yielded.first
    assert_equal jid, yielded.first.jid
  end

  def test_scan_arity_one_entry_can_be_deleted
    jid = SecureRandom.hex(12)
    add_member(jid: jid)
    # rubocop:disable Style/SymbolProc -- explicit 1-arg block exercises arity dispatch.
    @set.scan(jid) { |entry| entry.delete }
    # rubocop:enable Style/SymbolProc

    assert_equal 0, @set.size
  end

  def test_scan_legacy_arity_two_block_still_yields_value_score
    jid = SecureRandom.hex(12)
    add_member(jid: jid, score: 1234.5)
    yielded = []
    @set.scan(jid) { |value, score| yielded << [value, score] }

    assert_equal 1, yielded.size
    refute_nil yielded.first[0]
    assert_in_delta 1234.5, yielded.first[1], 0.0001
  end

  def test_scan_without_block_returns_enumerator
    assert_kind_of Enumerator, @set.scan('nope')
  end

  def test_scan_is_available_on_scheduled_and_dead
    assert_respond_to Wurk::ScheduledSet.new, :scan
    assert_respond_to Wurk::DeadSet.new, :scan
  end

  private

  def push_job(klass: 'FastApiJob', jid: nil)
    jid ||= SecureRandom.hex(12)
    payload = Wurk.dump_json('class' => klass, 'args' => [], 'queue' => @qname, 'jid' => jid)
    @pool.with do |c|
      c.call('SADD', 'queues', @qname)
      c.call('LPUSH', @rqname, payload)
    end
    jid
  end

  def add_member(jid:, score: 100.0)
    payload = Wurk.dump_json('class' => 'X', 'args' => [], 'jid' => jid, 'queue' => 'q')
    @pool.with { |c| c.call('ZADD', @set_name, score, payload) }
    payload
  end

  def queue_size
    @pool.with { |c| c.call('LLEN', @rqname) }
  end

  def clean
    @pool.with do |c|
      c.call('DEL', @rqname, @set_name)
      c.call('SREM', 'queues', @qname)
    end
  end
end
