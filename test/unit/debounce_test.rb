# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Wurk::Debounce and its Lua script, against real Redis.
#
# Two contracts are load-bearing here and every test below defends one of them:
# a burst collapses to exactly one entry (atomically, across producers), and
# that entry is an ordinary `schedule` member nothing can tell apart from a
# `perform_in`.
#
# Parallel safety: `schedule` is a global key, so every payload carries a class
# name derived from this test's namespace and every read filters on it — the
# per-worker DB plus the teardown FLUSHDB do the rest.
class DebounceTest < Wurk::Test::UnitCase
  parallelize_me!

  # Long enough that nothing under test is ever promoted mid-assertion by a
  # scheduler running in another suite.
  WAIT = 30

  def setup
    super
    @queue      = "q-#{Process.pid}-#{object_id}"
    @class_name = "DebounceJob@#{Process.pid}-#{object_id}"
    @pool       = Wurk.configuration.redis_pool
    @pool.with { |conn| Wurk::Lua::Loader.script_load_all(conn) }
  end

  # --- keys ------------------------------------------------------------

  def test_key_is_namespaced_under_debounce_prefix
    key = Wurk::Debounce.key_for(job)

    assert_match(/\Adebounce:[0-9a-f]{64}\z/, key)
    assert_equal Wurk::Keys.debounce(Wurk::Unique.digest_for(job)), key
  end

  # Same digest, two prefixes: a class using both features must not have one
  # policy's key silently answer for the other's.
  def test_key_does_not_collide_with_the_unique_lock_key
    refute_equal Wurk::Unique.lock_key_for(job), Wurk::Debounce.key_for(job)
  end

  def test_key_separates_distinct_identities
    assert_equal Wurk::Debounce.key_for(job(args: [1])), Wurk::Debounce.key_for(job(args: [1]))
    refute_equal Wurk::Debounce.key_for(job(args: [1])), Wurk::Debounce.key_for(job(args: [2]))
    refute_equal Wurk::Debounce.key_for(job(args: [1])), Wurk::Debounce.key_for(job(args: [1], queue: 'other'))
  end

  # The documented "collapse on a subset of the args" escape hatch: one hook,
  # shared with uniqueness, rather than a second near-identical one.
  def test_sidekiq_unique_context_narrows_the_key
    with_narrowing_worker do |name|
      a = job(klass: name, args: [7, 'ignored'])
      b = job(klass: name, args: [7, 'different'])

      assert_equal Wurk::Debounce.key_for(a), Wurk::Debounce.key_for(b)
      refute_equal Wurk::Debounce.key_for(a), Wurk::Debounce.key_for(job(klass: name, args: [8, 'ignored']))
    end
  end

  # An ActiveJob payload carries a fresh `job_id` and `enqueued_at` on every
  # push, so digesting its raw args would never collapse anything.
  def test_active_job_payload_keys_off_the_inner_job
    first  = active_job_payload('AJ@1')
    second = active_job_payload('AJ@2')

    assert_equal Wurk::Debounce.key_for(first), Wurk::Debounce.key_for(second)
  end

  # --- collapse --------------------------------------------------------

  def test_burst_collapses_to_one_entry_carrying_the_last_payload
    100.times { |i| Wurk::Debounce.schedule(job(jid: jid(i)), wait: WAIT) }

    assert_equal 1, mine.size, 'a burst must leave exactly one entry in `schedule`'
    assert_equal jid(99), mine.first.first['jid'], 'the LAST payload wins, not the first'
  end

  def test_first_push_opens_a_burst_and_the_next_replaces_it
    refute_predicate Wurk::Debounce.schedule(job(jid: jid('a')), wait: WAIT), :replaced?
    assert_predicate Wurk::Debounce.schedule(job(jid: jid('b')), wait: WAIT), :replaced?
  end

  # Distinct identities are distinct bursts — collapsing across them would
  # silently drop unrelated work.
  def test_distinct_identities_do_not_collapse_into_each_other
    Wurk::Debounce.schedule(job(args: [1]), wait: WAIT)
    Wurk::Debounce.schedule(job(args: [2]), wait: WAIT)

    assert_equal 2, mine.size
  end

  def test_quiet_period_is_extended_by_every_further_enqueue
    first = Wurk::Debounce.schedule(job(jid: jid('a')), wait: WAIT).at
    sleep 0.05
    later = Wurk::Debounce.schedule(job(jid: jid('b')), wait: WAIT).at

    assert_operator later, :>, first, 'each enqueue must push the fire time out again'
  end

  # --- starvation ------------------------------------------------------

  # The classic debounce bug: re-enqueued faster than `wait`, the entry pushes
  # its own fire time forward forever and the job never runs.
  def test_max_wait_pins_the_fire_time_under_continuous_re_enqueue
    opened = Wurk::Debounce.schedule(job(jid: jid('a')), wait: WAIT, max_wait: WAIT)
    5.times do |i|
      sleep 0.02
      capped = Wurk::Debounce.schedule(job(jid: jid(i.to_s)), wait: WAIT, max_wait: WAIT)

      assert_in_delta opened.at, capped.at, 1e-5, 'max_wait must stop the fire time drifting forward'
      assert_equal opened.opened_at, capped.opened_at, 'the burst start must survive every replacement'
    end
  end

  def test_max_wait_measures_from_the_first_enqueue_not_the_last
    opened = Wurk::Debounce.schedule(job(jid: jid('a')), wait: WAIT, max_wait: WAIT)
    sleep 0.05
    capped = Wurk::Debounce.schedule(job(jid: jid('b')), wait: WAIT, max_wait: WAIT)

    assert_in_delta opened.opened_at + WAIT, capped.at, 1e-5
  end

  def test_without_max_wait_the_fire_time_is_uncapped
    opened = Wurk::Debounce.schedule(job(jid: jid('a')), wait: WAIT)
    sleep 0.05
    extended = Wurk::Debounce.schedule(job(jid: jid('b')), wait: WAIT)

    assert_operator extended.at, :>, opened.opened_at + WAIT
  end

  # --- burst boundaries -------------------------------------------------

  # Once the poller promotes the pending member the burst is over. Carrying the
  # old `first` into the next one would cap a fresh burst against a deadline
  # that already passed and fire it instantly, forever.
  def test_promoted_entry_starts_a_new_burst
    opened = Wurk::Debounce.schedule(job(jid: jid('a')), wait: WAIT, max_wait: WAIT)
    @pool.with { |conn| mine_raw(conn).each { |pair| conn.call('ZREM', 'schedule', pair.first) } }
    sleep 0.02
    reopened = Wurk::Debounce.schedule(job(jid: jid('b')), wait: WAIT, max_wait: WAIT)

    refute_predicate reopened, :replaced?, 'a promoted entry is gone; this push opens a new burst'
    assert_operator reopened.opened_at, :>, opened.opened_at
    assert_operator reopened.at, :>, opened.at
  end

  # The state key has to outlive the entry it points at: if it expires while
  # the member is still pending, the next push sees nothing and ZADDs a second
  # entry beside it.
  def test_state_key_outlives_the_entry_it_guards
    Wurk::Debounce.schedule(job, wait: WAIT)
    ttl = @pool.with { |conn| conn.call('TTL', Wurk::Debounce.key_for(job)) }.to_i

    assert_operator ttl, :>, WAIT
    assert_in_delta WAIT + Wurk::Debounce::GRACE, ttl, 1
  end

  # --- wire compat ------------------------------------------------------

  def test_entry_is_an_ordinary_scheduled_member
    payload = job(jid: jid('a'), at: Time.now.to_f + 99, enqueued_at: 1)
    Wurk::Debounce.schedule(payload, wait: WAIT)
    stored, = mine.first

    refute stored.key?('at'),          '`at` is the score, never a member field'
    refute stored.key?('enqueued_at'), '`enqueued_at` is stamped at promotion, not here'
    assert_equal payload['jid'], stored['jid']
    assert_equal @queue, stored['queue']
  end

  def test_score_is_the_canonical_epoch_seconds_format
    outcome = Wurk::Debounce.schedule(job, wait: WAIT)
    _, score = mine.first

    assert_in_delta outcome.at, score.to_f, 1e-6
    assert_in_delta Time.now.to_f + WAIT, score.to_f, 5
  end

  def test_entry_is_readable_by_the_plain_scheduled_set_inspector
    id = jid('a')
    Wurk::Debounce.schedule(job(jid: id), wait: WAIT)
    entry = Wurk::ScheduledSet.new.find_job(id)

    refute_nil entry, 'a debounced job must be indistinguishable to ScheduledSet'
    assert_equal @class_name, entry.klass
    assert_equal @queue, entry.queue
  end

  # `push_scheduled` leaves the queues set alone — the promoter SADDs it. A
  # debounced job must not diverge, or it advertises a queue nothing has
  # enqueued to yet.
  def test_debounce_does_not_touch_the_queues_set
    Wurk::Debounce.schedule(job, wait: WAIT)

    assert_equal 0, @pool.with { |conn| conn.call('SISMEMBER', 'queues', @queue) }.to_i
  end

  # --- atomicity --------------------------------------------------------

  def test_whole_collapse_costs_one_round_trip
    spy = Wurk::Test::CommandSpy.new(@pool)
    Thread.current[:wurk_capsule] = spy
    Wurk::Debounce.schedule(job, wait: WAIT)
    Thread.current[:wurk_capsule] = nil

    assert_equal 1, spy.count, 'read-then-write is exactly what this script exists to avoid'
  ensure
    Thread.current[:wurk_capsule] = nil
  end

  # Concurrent producers on separate connections. Read-then-write here would
  # let two callers each see "nothing pending" and each ZADD.
  def test_concurrent_producers_leave_one_entry
    pool = Wurk::RedisPool.new(size: 8, url: Wurk::Test.redis_url, name: 'debounce-race')
    barrier = Queue.new
    threads = Array.new(8) do |i|
      Thread.new do
        barrier.pop
        Wurk::Debounce.schedule(job(jid: jid(i)), wait: WAIT, pool: pool)
      end
    end
    8.times { barrier << :go }
    threads.each(&:join)

    assert_equal 1, mine.size
  end

  # A pool retry after a lost reply re-runs the block; the script has to
  # converge on the entry it already wrote instead of adding a second.
  def test_replaying_the_same_push_converges_on_one_entry
    payload = job(jid: jid('a'))
    2.times { Wurk::Debounce.schedule(payload, wait: WAIT) }

    assert_equal 1, mine.size
    assert_equal payload['jid'], mine.first.first['jid']
  end

  # --- validation -------------------------------------------------------

  def test_wait_must_be_a_positive_number_of_seconds
    [0, -1, nil, 'five', Float::INFINITY].each do |bad|
      assert_raises(ArgumentError) { Wurk::Debounce.schedule(job, wait: bad) }
    end
  end

  def test_max_wait_must_be_a_positive_number_of_seconds
    assert_raises(ArgumentError) { Wurk::Debounce.schedule(job, wait: WAIT, max_wait: 0) }
    assert_raises(ArgumentError) { Wurk::Debounce.schedule(job, wait: WAIT, max_wait: 'soon') }
  end

  # A cap below the quiet period fires every burst at `first + max_wait`
  # whatever the traffic — a throttle wearing a debounce's name.
  def test_max_wait_shorter_than_wait_is_rejected
    error = assert_raises(ArgumentError) { Wurk::Debounce.schedule(job, wait: WAIT, max_wait: 1) }

    assert_match(/max_wait/, error.message)
  end

  private

  def jid(suffix) = "#{object_id}-#{suffix}"

  def job(klass: nil, args: [1], queue: nil, jid: 'seed', **extra)
    { 'class' => klass || @class_name, 'args' => args, 'queue' => queue || @queue,
      'jid' => jid, 'created_at' => 1_700_000_000.0 }.merge(extra.transform_keys(&:to_s))
  end

  # Fresh `job_id`/`enqueued_at` on every call: raw args like these never
  # repeat, which is exactly why the digest has to narrow to the inner job.
  def active_job_payload(job_id)
    { 'class' => 'Sidekiq::ActiveJob::Wrapper', 'queue' => @queue, 'jid' => job_id,
      'args' => [{ 'job_class' => @class_name, 'job_id' => job_id, 'arguments' => [1],
                   'enqueued_at' => job_id, 'executions' => 0 }] }
  end

  # ZRANGE the shared zset and keep only this test's members. Sibling suites
  # write non-JSON probe members there; skip those rather than blow up.
  def mine_raw(conn)
    conn.call('ZRANGE', 'schedule', 0, -1, 'WITHSCORES').filter_map do |member, score|
      [member, score] if JSON.parse(member)['class'] == @class_name
    rescue JSON::ParserError
      next
    end
  end

  def mine
    @pool.with { |conn| mine_raw(conn) }.map { |member, score| [JSON.parse(member), score] }
  end

  # A worker class that narrows its identity to the first arg, defined and
  # removed inside the block so the constant never leaks to a sibling test.
  def with_narrowing_worker
    name = "DebounceNarrowed#{object_id}"
    Object.const_set(name, Class.new do
      def self.sidekiq_unique_context(job) = job['args'].first
    end)
    yield name
  ensure
    Object.send(:remove_const, name) if Object.const_defined?(name)
  end
end
