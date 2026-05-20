# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Drives Wurk::SortedEntry shape (score, id, at, error?) and the
# parent-mutation paths (delete/reschedule/add_to_queue/retry/kill) via a
# real RetrySet against real Redis. Per-test JIDs keep the shared `retry`
# zset safe under across-file parallelism.
class SortedEntryTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns      = "#{Process.pid}-#{object_id}"
    @parent  = Wurk::RetrySet.new
    @pool    = Wurk.configuration.redis_pool
    @members = []
    @queues  = []
  end

  def teardown
    @pool.with do |c|
      @members.each { |m| c.call('ZREM', @parent.name, m) }
      @queues.each do |q|
        c.call('DEL', "queue:#{q}")
        c.call('SREM', 'queues', q)
      end
      c.call('ZREM', 'dead', *@members) unless @members.empty?
    end
  ensure
    super
  end

  # --- shape -------------------------------------------------------------

  def test_score_is_float
    entry = add_entry(score: 100.5)

    assert_in_delta 100.5, entry.score
    assert_kind_of Float, entry.score
  end

  def test_id_combines_score_and_jid
    entry = add_entry(score: 200.0, jid: 'abc')

    assert_equal '200.0|abc', entry.id
  end

  def test_at_returns_time_from_score
    entry = add_entry(score: 1_700_000_000.0)

    assert_kind_of ::Time, entry.at
    assert_in_delta 1_700_000_000.0, entry.at.to_f
  end

  def test_error_is_true_when_error_class_set
    entry = add_entry(item: base_item.merge('error_class' => 'RuntimeError'))

    assert_predicate entry, :error?
  end

  def test_error_is_false_without_error_class
    entry = add_entry

    refute_predicate entry, :error?
  end

  # --- delete ------------------------------------------------------------

  def test_delete_via_value_removes_from_parent
    entry = add_entry

    entry.delete

    assert_equal(0, @pool.with { |c| c.call('ZSCORE', @parent.name, entry.value) }.to_i)
  end

  # --- reschedule --------------------------------------------------------

  def test_reschedule_shifts_score
    entry = add_entry(score: 100.0)
    new_time = ::Time.at(500.0)

    entry.reschedule(new_time)

    actual = @pool.with { |c| c.call('ZSCORE', @parent.name, entry.value) }

    assert_in_delta 500.0, actual.to_f
  end

  # --- add_to_queue ------------------------------------------------------

  def test_add_to_queue_removes_and_pushes_to_queue
    queue = unique_queue
    entry = add_entry(item: base_item('retry_count' => 5, 'queue' => queue))

    entry.add_to_queue

    assert_equal(0, @pool.with { |c| c.call('ZSCORE', @parent.name, entry.value) }.to_i)
    assert_equal(1, @pool.with { |c| c.call('LLEN', "queue:#{queue}") })
  end

  def test_add_to_queue_decrements_retry_count
    queue = unique_queue
    entry = add_entry(item: base_item('retry_count' => 3, 'queue' => queue))

    entry.add_to_queue

    raw = @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, 0) }.first

    assert_equal 2, Wurk.load_json(raw)['retry_count']
  end

  # --- retry -------------------------------------------------------------

  def test_retry_removes_and_pushes_without_decrement
    queue = unique_queue
    entry = add_entry(item: base_item('retry_count' => 3, 'queue' => queue))

    entry.retry

    raw = @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, 0) }.first

    assert_equal 3, Wurk.load_json(raw)['retry_count']
  end

  # --- kill --------------------------------------------------------------

  def test_kill_removes_from_parent_and_adds_to_dead
    entry = add_entry

    entry.kill

    assert_equal(0, @pool.with { |c| c.call('ZSCORE', @parent.name, entry.value) }.to_i)
    refute_nil(@pool.with { |c| c.call('ZSCORE', 'dead', entry.value) })
  end

  private

  def add_entry(score: 100.0, jid: nil, item: nil)
    jid ||= SecureRandom.hex(12)
    item ||= base_item('jid' => jid)
    item['jid'] = jid
    payload = Wurk.dump_json(item)
    @pool.with { |c| c.call('ZADD', @parent.name, score, payload) }
    @members << payload
    Wurk::SortedEntry.new(@parent, score, payload)
  end

  def base_item(extra = {})
    {
      'class' => 'SortedEntryTestJob',
      'args' => [],
      'queue' => 'default',
      'jid' => SecureRandom.hex(12),
      'created_at' => Time.now.to_f
    }.merge(extra)
  end

  def unique_queue
    q = "se-q-#{@ns}-#{@queues.size}"
    @queues << q
    q
  end
end
