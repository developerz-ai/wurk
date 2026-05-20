# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Drives Wurk::SortedSet + Wurk::JobSet against a real Redis `retry` zset.
# Shared global key means tests use unique payloads per instance and clean
# them up; assertions use lower bounds where the shared set is observed.
class JobSetTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns      = "#{Process.pid}-#{object_id}"
    @set     = Wurk::RetrySet.new
    @pool    = Wurk.configuration.redis_pool
    @members = []
    @queues  = []
  end

  def teardown
    @pool.with do |c|
      @members.each do |m|
        c.call('ZREM', @set.name, m)
        c.call('ZREM', 'dead', m)
      end
      @queues.each do |q|
        c.call('DEL', "queue:#{q}")
        c.call('SREM', 'queues', q)
      end
    end
  ensure
    super
  end

  # --- SortedSet ---------------------------------------------------------

  def test_size_is_zcard
    add_member
    add_member

    assert_operator @set.size, :>=, 2
  end

  def test_clear_unlinks
    add_member

    assert @set.clear
    # NB: shared key; another test may immediately re-populate. Assert our
    # member is gone rather than the cardinality.
    @members.each do |m|
      assert_equal(0, @pool.with { |c| c.call('ZSCORE', @set.name, m) }.to_i)
    end
  end

  def test_as_json_returns_name
    assert_equal({ name: 'retry' }, @set.as_json)
  end

  def test_includes_enumerable
    assert_includes Wurk::SortedSet.ancestors, Enumerable
  end

  # --- scan --------------------------------------------------------------

  def test_scan_yields_matching_payloads
    jid = SecureRandom.hex(12)
    add_member(jid: jid)
    yielded = []
    @set.scan(jid) { |value, score| yielded << [value, score] }

    assert_equal 1, yielded.size
    refute_nil yielded.first.last
  end

  def test_scan_returns_enumerator_without_block
    assert_kind_of Enumerator, @set.scan('nonexistent')
  end

  # --- each --------------------------------------------------------------

  def test_each_yields_sorted_entries
    add_member
    entries = @set.to_a.select { |e| @members.include?(e.value) }

    refute_empty entries
    assert_kind_of Wurk::SortedEntry, entries.first
  end

  def test_each_returns_reverse_score_order
    add_member(score: 100.0)
    add_member(score: 300.0)
    add_member(score: 200.0)
    ours = @set.to_a.select { |e| @members.include?(e.value) }
    scores = ours.map(&:score)

    assert_equal scores.sort.reverse, scores
  end

  # --- schedule ----------------------------------------------------------

  def test_schedule_zadds_payload
    message = base_item
    @set.schedule(::Time.now.to_f + 60, message)
    payload = Wurk.dump_json(message)
    @members << payload

    refute_nil(@pool.with { |c| c.call('ZSCORE', @set.name, payload) })
  end

  # --- pop_each ----------------------------------------------------------

  def test_pop_each_drains_in_score_order
    private_set = test_private_set
    seed_private(private_set, [[200, 'b'], [100, 'a'], [300, 'c']])
    yielded = []
    private_job_set(private_set).pop_each { |value, score| yielded << [Wurk.load_json(value)['jid'], score] }

    assert_equal %w[a b c], yielded.map(&:first)
    assert_equal [100.0, 200.0, 300.0], yielded.map(&:last)
  ensure
    @pool.with { |c| c.call('DEL', private_set) }
  end

  # --- fetch -------------------------------------------------------------

  def test_fetch_by_numeric_score
    add_member(score: 1234.5)
    entries = @set.fetch(1234.5)

    refute_empty entries
    assert(entries.all? { |e| (e.score - 1234.5).abs < 0.0001 })
  end

  def test_fetch_by_time
    score = ::Time.now.to_f + 42
    add_member(score: score)
    entries = @set.fetch(::Time.at(score))

    assert(entries.any? { |e| @members.include?(e.value) })
  end

  def test_fetch_by_range
    score = 5_000.0 + rand(1_000)
    add_member(score: score)
    entries = @set.fetch((score - 1)..(score + 1))

    assert(entries.any? { |e| @members.include?(e.value) })
  end

  def test_fetch_filters_by_jid
    jid = SecureRandom.hex(12)
    add_member(score: 9999.0, jid: jid)
    add_member(score: 9999.0)

    entries = @set.fetch(9999.0, jid)

    assert_equal 1, entries.size
    assert_equal jid, entries.first.jid
  end

  def test_fetch_raises_on_bad_score
    assert_raises(ArgumentError) { @set.fetch('not a score') }
  end

  # --- find_job ----------------------------------------------------------

  def test_find_job_returns_entry_for_known_jid
    jid = SecureRandom.hex(12)
    add_member(jid: jid)

    entry = @set.find_job(jid)

    refute_nil entry
    assert_equal jid, entry.jid
  end

  def test_find_job_returns_nil_for_unknown_jid
    assert_nil @set.find_job('deadbeef' * 3)
  end

  # --- delete_by_value ---------------------------------------------------

  def test_delete_by_value_removes_exact_payload
    payload = add_member

    assert @set.delete_by_value(@set.name, payload)
    assert_equal(0, @pool.with { |c| c.call('ZSCORE', @set.name, payload) }.to_i)
  end

  def test_delete_by_value_returns_false_for_missing
    refute @set.delete_by_value(@set.name, 'never-existed')
  end

  # --- delete_by_jid -----------------------------------------------------

  def test_delete_by_jid_removes_member
    jid = SecureRandom.hex(12)
    payload = add_member(score: 4242.0, jid: jid)

    assert @set.delete_by_jid(4242.0, jid)
    assert_equal(0, @pool.with { |c| c.call('ZSCORE', @set.name, payload) }.to_i)
  end

  def test_delete_aliases_delete_by_jid
    jid = SecureRandom.hex(12)
    add_member(score: 7777.0, jid: jid)

    assert @set.delete(7777.0, jid)
  end

  def test_delete_by_jid_returns_false_when_no_match
    refute @set.delete_by_jid(0.123, 'never')
  end

  # --- remove_job --------------------------------------------------------

  def test_remove_job_via_entry
    payload = add_member
    entry = Wurk::SortedEntry.new(@set, 100.0, payload)

    assert @set.remove_job(entry)
  end

  # --- retry_all ---------------------------------------------------------

  def test_retry_all_drains_set_and_pushes_to_queues
    queue = unique_queue
    private_set = test_private_set
    rows = (0...3).map { |i| [10 + i, "ra-#{i}-#{@ns}", { 'queue' => queue }] }
    seed_private(private_set, rows)
    count = private_job_set(private_set).retry_all

    assert_equal 3, count
    assert_drained(private_set, into_queue: queue, expected: 3)
  ensure
    @pool.with { |c| c.call('DEL', private_set) }
  end

  # --- kill_all ----------------------------------------------------------

  def test_kill_all_moves_entries_to_dead
    private_set = test_private_set
    rows = (0...3).map { |i| [10 + i, "ka-#{i}-#{@ns}"] }
    payloads = seed_private(private_set, rows)
    count = private_job_set(private_set).kill_all
    @members.concat(payloads)

    assert_equal 3, count
    assert_drained(private_set, into_dead: payloads)
  ensure
    @pool.with { |c| c.call('DEL', private_set) }
  end

  private

  def assert_drained(set_name, into_queue: nil, expected: nil, into_dead: nil)
    assert_equal(0, @pool.with { |c| c.call('ZCARD', set_name) })
    assert_equal(expected, @pool.with { |c| c.call('LLEN', "queue:#{into_queue}") }) if into_queue

    Array(into_dead).each { |p| refute_nil(@pool.with { |c| c.call('ZSCORE', 'dead', p) }) }
  end

  def add_member(score: 100.0, jid: nil)
    jid ||= SecureRandom.hex(12)
    item = base_item('jid' => jid)
    payload = Wurk.dump_json(item)
    @pool.with { |c| c.call('ZADD', @set.name, score, payload) }
    @members << payload
    payload
  end

  def base_item(extra = {})
    {
      'class' => 'JobSetTestJob',
      'args' => [],
      'queue' => 'default',
      'jid' => SecureRandom.hex(12),
      'created_at' => Time.now.to_f
    }.merge(extra)
  end

  # Seed a (score, jid[, extra]) triple-list into a private ZSET. Returns
  # the raw JSON payloads in input order so callers can assert on them.
  def seed_private(set_name, rows)
    payloads = rows.map do |row|
      _score, jid, extra = row
      Wurk.dump_json(base_item({ 'jid' => jid }.merge(extra || {})))
    end
    @pool.with do |c|
      rows.zip(payloads).each { |(score, _jid, _e), payload| c.call('ZADD', set_name, score, payload) }
    end
    payloads
  end

  def private_job_set(set_name)
    Class.new(Wurk::JobSet) { define_method(:initialize) { super(set_name) } }.new
  end

  def test_private_set
    "wurktest-jobset-#{@ns}-#{rand(1_000_000)}"
  end

  def unique_queue
    q = "js-q-#{@ns}-#{@queues.size}"
    @queues << q
    q
  end
end
