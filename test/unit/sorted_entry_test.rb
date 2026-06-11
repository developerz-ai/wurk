# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Drives Wurk::SortedEntry shape (score, id, at, error?) and the
# parent-mutation paths (delete/reschedule/add_to_queue/retry/kill) via a
# RetrySet against real Redis.
#
# Parallel safety: the parent RetrySet is namespaced as "retry-<pid>-<oid>"
# so every entry mutation is isolated. `SortedEntry#kill` always writes to
# the global `dead` ZSET (production code uses `DeadSet.new` directly); we
# track those payloads in `@dead_members` and ZREM them in teardown.
class SortedEntryTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns           = "#{Process.pid}-#{object_id}"
    @parent       = Wurk::RetrySet.new("retry-#{@ns}")
    @pool         = Wurk.configuration.redis_pool
    @dead_members = []
    @queues       = []
  end

  def teardown
    @pool.with do |c|
      c.call('UNLINK', @parent.name)
      @queues.each do |q|
        c.call('DEL', "queue:#{q}")
        c.call('SREM', 'queues', q)
      end
      c.call('ZREM', 'dead', *@dead_members) unless @dead_members.empty?
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

  # --- Sidekiq::SortedEntry drop-in alias --------------------------------

  # The class iterated out of RetrySet/ScheduledSet/DeadSet must answer to the
  # public Sidekiq name — third-party gems and dashboard code branch on
  # `entry.is_a?(Sidekiq::SortedEntry)`. See issue #105.
  def test_entries_from_each_sorted_set_are_sidekiq_sorted_entry
    [Wurk::RetrySet, Wurk::ScheduledSet, Wurk::DeadSet].each do |klass|
      name = "#{klass.name.split('::').last.downcase}-#{@ns}"
      set  = klass.new(name)
      @pool.with { |c| c.call('ZADD', name, 100.0, Wurk.dump_json(base_item)) }

      entry = set.first

      assert_kind_of Sidekiq::SortedEntry, entry, "#{klass} entry is not a Sidekiq::SortedEntry"
    ensure
      @pool.with { |c| c.call('UNLINK', name) }
    end
  end

  # --- delete ------------------------------------------------------------

  def test_delete_via_value_removes_from_parent
    entry = add_entry

    entry.delete

    assert_equal(0, @pool.with { |c| c.call('ZSCORE', @parent.name, entry.value) }.to_i)
  end

  # When the entry is built from a parsed Hash (no cached `value` bytes), the
  # `@value` else branch falls back to delete_by_jid (score-bracket + jid scan).
  def test_delete_falls_back_to_jid_when_no_cached_value
    jid = SecureRandom.hex(12)
    item = base_item('jid' => jid)
    payload = Wurk.dump_json(item)
    @pool.with { |c| c.call('ZADD', @parent.name, 100.0, payload) }
    # Hash item ⇒ @value is nil ⇒ delete must take the delete_by_jid branch.
    entry = Wurk::SortedEntry.new(@parent, 100.0, item)

    assert_nil entry.instance_variable_get(:@value)
    entry.delete

    assert_equal(0, @pool.with { |c| c.call('ZSCORE', @parent.name, payload) }.to_i)
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

  # Sidekiq's add_to_queue pushes the payload untouched — the decrement
  # belongs to #retry (see #206).
  def test_add_to_queue_keeps_retry_count
    queue = unique_queue
    entry = add_entry(item: base_item('retry_count' => 3, 'queue' => queue))

    entry.add_to_queue

    raw = @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, 0) }.first

    assert_equal 3, Wurk.load_json(raw)['retry_count']
  end

  # No `retry_count` key ⇒ enqueue the message unchanged, never inserting
  # a retry_count field.
  def test_add_to_queue_leaves_message_unchanged_without_retry_count
    queue = unique_queue
    entry = add_entry(item: base_item('queue' => queue))

    entry.add_to_queue

    raw = @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, 0) }.first

    refute Wurk.load_json(raw).key?('retry_count')
  end

  # --- retry -------------------------------------------------------------

  # remove_job's `return nil unless @parent.remove_job(self)` then-branch:
  # when the entry was already removed (not in the set), the block must not
  # run and the method returns nil — no duplicate enqueue.
  def test_retry_is_noop_when_entry_already_gone
    queue = unique_queue
    jid = SecureRandom.hex(12)
    item = base_item('retry_count' => 3, 'queue' => queue, 'jid' => jid)
    payload = Wurk.dump_json(item)
    # Build an entry whose payload was never added to the parent set.
    entry = Wurk::SortedEntry.new(@parent, 100.0, payload)

    assert_nil entry.retry
    assert_equal(0, @pool.with { |c| c.call('LLEN', "queue:#{queue}") })
  end

  # The count was bumped when the job entered the retry set and the next
  # failure bumps it again — Sidekiq decrements here so a manual "Retry now"
  # doesn't consume an attempt (#206).
  def test_retry_decrements_retry_count
    queue = unique_queue
    entry = add_entry(item: base_item('retry_count' => 3, 'queue' => queue))

    entry.retry

    raw = @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, 0) }.first

    assert_equal 2, Wurk.load_json(raw)['retry_count']
  end

  # No `retry_count` key ⇒ the decrement guard's else branch: push unchanged.
  def test_retry_without_retry_count_pushes_unchanged
    queue = unique_queue
    entry = add_entry(item: base_item('queue' => queue))

    entry.retry

    raw = @pool.with { |c| c.call('LRANGE', "queue:#{queue}", 0, 0) }.first

    refute Wurk.load_json(raw).key?('retry_count')
  end

  # --- kill --------------------------------------------------------------

  def test_kill_removes_from_parent_and_adds_to_dead
    entry = add_entry
    @dead_members << entry.value

    entry.kill

    assert_equal(0, @pool.with { |c| c.call('ZSCORE', @parent.name, entry.value) }.to_i)
    refute_nil(@pool.with { |c| c.call('ZSCORE', 'dead', entry.value) })
  end

  # Sidekiq fires death handlers on API/UI kills by default, synthesizing
  # RuntimeError("Job killed by API") with a backtrace (#207).
  def test_kill_fires_death_handlers_by_default
    entry = add_entry
    @dead_members << entry.value

    with_death_handler do |received|
      entry.kill

      ex = received[entry.jid]

      assert_instance_of RuntimeError, ex
      assert_equal Wurk::DeadSet::API_KILL_MESSAGE, ex.message
      refute_nil ex.backtrace
    end
  end

  private

  # Registers a jid-keyed capture handler for the block — keyed by jid
  # because the handler list is process-global and this class is parallel.
  def with_death_handler
    received = {}
    handler = ->(job, ex) { received[job['jid']] = ex }
    Wurk.configuration.death_handlers << handler
    yield received
  ensure
    Wurk.configuration.death_handlers.delete(handler)
  end

  def add_entry(score: 100.0, jid: nil, item: nil)
    jid ||= SecureRandom.hex(12)
    item ||= base_item('jid' => jid)
    item['jid'] = jid
    payload = Wurk.dump_json(item)
    @pool.with { |c| c.call('ZADD', @parent.name, score, payload) }
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
