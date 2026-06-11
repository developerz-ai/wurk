# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Drives Wurk::SortedSet + Wurk::JobSet against a real Redis sorted set.
#
# Parallel safety: every test operates on a per-instance ZSET named
# "retry-<pid>-<object_id>". Where `kill_all` writes to the global `dead`
# ZSET (because production `JobSet#kill_all` instantiates `DeadSet.new` with
# the canonical key), we track those payloads in `@dead_members` and ZREM
# them in teardown so we don't leak across runs.
class JobSetTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @ns           = "#{Process.pid}-#{object_id}"
    @set          = Wurk::RetrySet.new("retry-#{@ns}")
    @pool         = Wurk.configuration.redis_pool
    @dead_members = []
    @queues       = []
  end

  def teardown
    @pool.with do |c|
      c.call('UNLINK', @set.name)
      @dead_members.each { |m| c.call('ZREM', 'dead', m) }
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

    assert_equal 2, @set.size
  end

  def test_clear_unlinks
    add_member

    assert @set.clear
    assert_equal 0, @set.size
  end

  def test_default_name_is_retry
    assert_equal 'retry', Wurk::RetrySet.new.name
  end

  def test_as_json_returns_name
    assert_equal({ name: @set.name }, @set.as_json)
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

  # Drives the no-block Enumerator returned by scan, which re-enters the base
  # SortedSet#scan *with* a block — covering the line 38 else-branch
  # (block_given? true → fall through to the ZSCAN loop).
  def test_scan_enumerator_iterates_payloads
    jid = SecureRandom.hex(12)
    add_member(jid: jid)

    pairs = @set.scan(jid).to_a

    assert_equal 1, pairs.size
    assert_kind_of Float, pairs.first.last
  end

  # Line 38 then-branch (`return enum_for(:scan, ...)` in the base
  # SortedSet#scan) is unreachable through the public API: Wurk prepends
  # Wurk::API::Fast::SortedSetExt onto SortedSet, and its #scan handles the
  # no-block case itself (its own `return enum_for unless block`), so it only
  # ever calls `super` *with* a block. The base scan therefore always sees
  # block_given? == true and never executes its own enum_for guard.
  def test_base_scan_enum_for_guard_is_shadowed_by_prepended_ext
    ancestors = Wurk::SortedSet.ancestors

    assert_operator ancestors.index(Wurk::API::Fast::SortedSetExt),
                    :<,
                    ancestors.index(Wurk::SortedSet),
                    'prepend order regressed; base scan no-block guard may now be reachable'
    skip 'base SortedSet#scan no-block guard is shadowed by the prepended SortedSetExt#scan'
  end

  # Covers line 46 else-branch: ZSCAN returns a non-zero cursor (multi-page)
  # once the ZSET exceeds Redis's listpack encoding threshold
  # (zset-max-listpack-entries default 128), so the loop iterates without
  # breaking on the first page.
  def test_scan_spans_multiple_pages
    150.times { |i| add_member(score: i.to_f, jid: format('pagescan%03d', i)) }

    yielded = @set.scan('pagescan', 10).to_a

    assert_equal 150, yielded.size
  end

  # --- each --------------------------------------------------------------

  def test_each_yields_sorted_entries
    add_member
    entries = @set.to_a

    refute_empty entries
    assert_kind_of Wurk::SortedEntry, entries.first
  end

  def test_each_returns_reverse_score_order
    add_member(score: 100.0)
    add_member(score: 300.0)
    add_member(score: 200.0)
    scores = @set.to_a.map(&:score)

    assert_equal scores.sort.reverse, scores
  end

  # Covers line 76 then-branch: each with no block returns an Enumerator
  # rather than iterating.
  def test_each_returns_enumerator_without_block
    assert_kind_of Enumerator, @set.each
  end

  # Covers line 88 else-branch: a first page that is exactly PAGE_SIZE full
  # forces a second ZRANGE page (slice.size < PAGE_SIZE is false), so the
  # loop increments the page counter instead of breaking.
  def test_each_pages_past_first_full_page
    total = Wurk::SortedSet::PAGE_SIZE + 5
    total.times { |i| add_member(score: i.to_f) }

    count = @set.each { |_e| } # rubocop:disable Lint/EmptyBlock

    assert_equal total, count
    assert_equal total, @set.to_a.size
  end

  # --- schedule ----------------------------------------------------------

  def test_schedule_zadds_payload
    message = base_item
    @set.schedule(::Time.now.to_f + 60, message)
    payload = Wurk.dump_json(message)

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

  # Line 106 else-branch (the flat `[value, score]` ZPOPMIN shape) is
  # unreachable on the supported redis-client: ZPOPMIN ... COUNT 1 always
  # returns the nested `[[value, score]]` form here. The else exists only as a
  # defensive normalizer for older redis-client builds; forcing it would
  # require mocking the connection, which the test policy forbids for Redis.
  def test_pop_each_flat_result_shape_is_unreachable_with_current_redis_client
    result = @pool.with do |c|
      c.call('DEL', @set.name)
      c.call('ZADD', @set.name, 1.0, 'x')
      c.call('ZPOPMIN', @set.name, 1)
    end

    assert_kind_of Array, result.first, 'nested shape regressed; revisit pop_each else-branch coverage'
    skip 'flat ZPOPMIN shape not produced by supported redis-client; else-branch is defensive only'
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

    refute_empty entries
  end

  def test_fetch_by_range
    score = 5_000.0 + rand(1_000)
    add_member(score: score)
    entries = @set.fetch((score - 1)..(score + 1))

    refute_empty entries
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

  # Covers line 159 else-branch: ZSCAN MATCH glob matches a payload because
  # the search string appears as a substring (here inside args), but that
  # entry's actual jid field differs, so the `return entry if ...` guard is
  # false and the scan continues — ultimately returning nil.
  def test_find_job_skips_substring_match_with_different_jid
    needle = SecureRandom.hex(12)
    decoy = base_item('jid' => SecureRandom.hex(12), 'args' => ["wraps-#{needle}-here"])
    payload = Wurk.dump_json(decoy)
    @pool.with { |c| c.call('ZADD', @set.name, 5.0, payload) }

    assert_nil @set.find_job(needle)
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

  # Covers line 190 then-branch deterministically: a single row sits at the
  # requested score, it parses cleanly, but its jid differs from the one we ask
  # to delete — so `next unless parsed && parsed['jid'] == jid` fires `next`,
  # the loop exhausts, and delete_by_jid returns false. (Equal-score ZREM
  # ordering is lexical-by-member, so a two-member variant couldn't guarantee
  # the non-matching row is visited first; one decoy row makes it certain.)
  def test_delete_by_jid_skips_parsed_row_with_different_jid
    score = 6161.0
    decoy = add_member(score: score) # random jid != the one we delete

    refute @set.delete_by_jid(score, SecureRandom.hex(12))
    refute_nil(@pool.with { |c| c.call('ZSCORE', @set.name, decoy) }, 'decoy must remain — no ZREM should have fired')
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
    @dead_members.concat(payloads)

    assert_equal 3, count
    assert_drained(private_set, into_dead: payloads)
  ensure
    @pool.with { |c| c.call('DEL', private_set) }
  end

  # `each(&:kill)` equivalence with Sidekiq (#207): one death-handler call
  # per entry by default.
  def test_kill_all_fires_death_handlers_per_entry
    private_set = seed_killable_set('kadh')

    with_death_handler do |received|
      private_job_set(private_set).kill_all

      mine = received.select { |jid, _| jid.end_with?(@ns) }

      assert_equal 2, mine.size
      assert(mine.values.all? { |ex| ex.message == Wurk::DeadSet::API_KILL_MESSAGE })
    end
  ensure
    @pool.with { |c| c.call('DEL', private_set) } if private_set
  end

  def test_kill_all_notify_false_skips_death_handlers
    private_set = seed_killable_set('kanf')

    with_death_handler do |received|
      private_job_set(private_set).kill_all(notify_failure: false)

      assert_empty(received.select { |jid, _| jid.end_with?(@ns) })
    end
  ensure
    @pool.with { |c| c.call('DEL', private_set) } if private_set
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

  # Two-entry private set whose jids end with @ns so handler captures can be
  # filtered. Returns the set name; payloads are tracked for dead cleanup.
  def seed_killable_set(prefix)
    private_set = test_private_set
    rows = (0...2).map { |i| [10 + i, "#{prefix}-#{i}-#{@ns}"] }
    @dead_members.concat(seed_private(private_set, rows))
    private_set
  end

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

  def unique_queue
    q = "js-q-#{@ns}-#{@queues.size}"
    @queues << q
    q
  end
end
