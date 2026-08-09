# frozen_string_literal: true

require_relative '../test_helper'

# Wurk::Throttle and its Lua script, against real Redis.
#
# Three contracts carry the policy and every test below defends one: at most
# one job is admitted per identity per slot, the slots are epoch-aligned rather
# than measured from first use, and a dropped caller is told who beat it.
#
# Parallel safety: every payload's class name is derived from this test's
# namespace, so its identity digest — and therefore its whole key prefix — is
# unique to this test; the per-worker DB and the teardown FLUSHDB do the rest.
class ThrottleTest < Wurk::Test::UnitCase
  parallelize_me!

  # An hour. Wide enough that a slot boundary landing inside a test is a
  # once-in-millions event rather than a flake budget, and the boundary tests
  # that do need one use `slot: 1` and sleep to it deliberately.
  SLOT = 3600

  def setup
    super
    @queue      = "q-#{Process.pid}-#{object_id}"
    @class_name = "ThrottleJob@#{Process.pid}-#{object_id}"
    @pool       = Wurk.configuration.redis_pool
    @pool.with { |conn| Wurk::Lua::Loader.script_load_all(conn) }
  end

  # --- keys ------------------------------------------------------------

  def test_prefix_is_namespaced_under_the_throttle_prefix
    prefix = Wurk::Throttle.key_prefix_for(job)

    assert_match(/\Athrottle:[0-9a-f]{64}\z/, prefix)
    assert_equal Wurk::Keys.throttle(Wurk::Unique.digest_for(job)), prefix
  end

  # One digest, three prefixes: a class using more than one policy must not
  # have one of them silently answer for another.
  def test_prefix_does_not_collide_with_the_unique_or_debounce_keys
    refute_equal Wurk::Unique.lock_key_for(job), Wurk::Throttle.key_prefix_for(job)
    refute_equal Wurk::Debounce.key_for(job), Wurk::Throttle.key_prefix_for(job)
  end

  def test_prefix_separates_distinct_identities
    assert_equal Wurk::Throttle.key_prefix_for(job(args: [1])), Wurk::Throttle.key_prefix_for(job(args: [1]))
    refute_equal Wurk::Throttle.key_prefix_for(job(args: [1])), Wurk::Throttle.key_prefix_for(job(args: [2]))
    refute_equal Wurk::Throttle.key_prefix_for(job(args: [1])),
                 Wurk::Throttle.key_prefix_for(job(args: [1], queue: 'other'))
  end

  # The documented "throttle on a subset of the args" escape hatch: the hook
  # uniqueness and debounce already use, not a third one.
  def test_sidekiq_unique_context_narrows_the_prefix
    with_narrowing_worker do |name|
      a = job(klass: name, args: [7, 'ignored'])
      b = job(klass: name, args: [7, 'different'])

      assert_equal Wurk::Throttle.key_prefix_for(a), Wurk::Throttle.key_prefix_for(b)
      refute_equal Wurk::Throttle.key_prefix_for(a), Wurk::Throttle.key_prefix_for(job(klass: name, args: [8]))
    end
  end

  # An ActiveJob payload carries a fresh `job_id` on every push, so digesting
  # its raw args would admit every one of them.
  def test_active_job_payload_keys_off_the_inner_job
    assert_equal Wurk::Throttle.key_prefix_for(active_job_payload('AJ@1')),
                 Wurk::Throttle.key_prefix_for(active_job_payload('AJ@2'))
  end

  # --- admission -------------------------------------------------------

  def test_first_push_in_a_slot_is_admitted
    assert_predicate Wurk::Throttle.admit(job(jid: jid('a')), slot: SLOT), :admitted?
  end

  def test_later_pushes_in_the_same_slot_are_dropped
    Wurk::Throttle.admit(job(jid: jid('a')), slot: SLOT)
    outcomes = 9.times.map { |i| Wurk::Throttle.admit(job(jid: jid(i)), slot: SLOT) }

    assert(outcomes.all?(&:dropped?), 'a slot admits one job, not ten')
    assert(outcomes.none?(&:admitted?), 'admitted? and dropped? must be complements')
  end

  # Distinct identities are distinct slots — sharing them would drop unrelated
  # work as though it were a duplicate.
  def test_distinct_identities_hold_separate_slots
    assert_predicate Wurk::Throttle.admit(job(args: [1], jid: jid('a')), slot: SLOT), :admitted?
    assert_predicate Wurk::Throttle.admit(job(args: [2], jid: jid('b')), slot: SLOT), :admitted?
  end

  def test_a_dropped_push_does_not_take_over_the_slot
    Wurk::Throttle.admit(job(jid: jid('winner')), slot: SLOT)
    Wurk::Throttle.admit(job(jid: jid('loser')), slot: SLOT)

    held_by = @pool.with { |conn| conn.call('GET', slot_keys.first) }

    assert_equal jid('winner'), held_by
  end

  # --- return value ----------------------------------------------------

  # The documented contract: the Outcome names whoever owns the slot. A loser
  # cannot recover that for itself — by the time it asks the slot may have
  # closed, and asking costs a second round trip that races the boundary.
  def test_dropped_outcome_names_the_incumbent_not_the_caller
    Wurk::Throttle.admit(job(jid: jid('winner')), slot: SLOT)
    dropped = Wurk::Throttle.admit(job(jid: jid('loser')), slot: SLOT)

    assert_equal jid('winner'), dropped.jid
  end

  def test_admitted_outcome_names_the_caller
    assert_equal jid('a'), Wurk::Throttle.admit(job(jid: jid('a')), slot: SLOT).jid
  end

  # Both outcomes report the same boundary: it is the earliest this identity
  # can be admitted again, which is the only thing a dropped caller can act on.
  def test_both_outcomes_report_the_slot_boundary
    admitted = Wurk::Throttle.admit(job(jid: jid('a')), slot: SLOT)
    dropped  = Wurk::Throttle.admit(job(jid: jid('b')), slot: SLOT)

    assert_equal admitted.slot_ends_at, dropped.slot_ends_at
    assert_operator admitted.slot_ends_at, :>, Time.now.to_f
    assert_operator admitted.slot_ends_at, :<=, Time.now.to_f + SLOT
  end

  # --- slot alignment --------------------------------------------------

  # Aligned to the epoch, not to first use. A cooldown starting at first use is
  # a rolling rate limit; a slot is a landmark every producer names identically.
  def test_slots_are_aligned_to_the_epoch
    outcome = Wurk::Throttle.admit(job(jid: jid('a')), slot: SLOT)

    assert_equal 0, outcome.slot_ends_at.to_i % SLOT, 'a boundary must fall on a multiple of the slot width'
    assert_in_delta outcome.slot_ends_at, outcome.slot_ends_at.to_i, 1e-6, 'boundaries are whole seconds'
  end

  # The slot index lives in the key name, which is what leaves the TTL with
  # nothing to decide: two adjacent slots are two different keys.
  def test_the_slot_index_is_part_of_the_key_name
    outcome = Wurk::Throttle.admit(job(jid: jid('a')), slot: SLOT)
    index = (outcome.slot_ends_at / SLOT).to_i - 1

    assert_equal ["#{Wurk::Throttle.key_prefix_for(job)}:#{index}"], slot_keys
  end

  # The next slot admits again — the whole point of a ceiling rather than a
  # one-shot lock.
  def test_the_next_slot_admits_again
    first = Wurk::Throttle.admit(job(jid: jid('a')), slot: 1)

    assert_predicate first, :admitted?
    assert_predicate Wurk::Throttle.admit(job(jid: jid('b')), slot: 1), :dropped?

    sleep([first.slot_ends_at - Time.now.to_f, 0].max + 0.1)
    second = Wurk::Throttle.admit(job(jid: jid('c')), slot: 1)

    assert_predicate second, :admitted?
    assert_operator second.slot_ends_at, :>, first.slot_ends_at
  end

  # The TTL is garbage collection, not the throttle: it never outlives the slot
  # by more than the rounding, and the next slot reads a different name anyway.
  def test_the_key_expires_at_its_own_slot_boundary
    outcome = Wurk::Throttle.admit(job(jid: jid('a')), slot: SLOT)
    ttl = @pool.with { |conn| conn.call('TTL', slot_keys.first) }.to_i

    assert_operator ttl, :>, 0
    assert_operator ttl, :<=, SLOT
    assert_in_delta outcome.slot_ends_at - Time.now.to_f, ttl, 2
  end

  # --- re-pushes -------------------------------------------------------

  # A retry or a scheduled promotion runs the client chain again carrying the
  # same jid. Reading that as a duplicate would lose the job outright.
  def test_the_same_jid_is_re_admitted_rather_than_dropped
    payload = job(jid: jid('a'))

    assert_predicate Wurk::Throttle.admit(payload, slot: SLOT), :admitted?
    repush = Wurk::Throttle.admit(payload, slot: SLOT)

    assert_predicate repush, :admitted?, 'a re-push of the winner is not a duplicate of itself'
    assert_equal jid('a'), repush.jid
  end

  def test_replaying_the_same_push_still_holds_one_slot
    payload = job(jid: jid('a'))
    3.times { Wurk::Throttle.admit(payload, slot: SLOT) }

    assert_equal 1, slot_keys.size
  end

  # --- atomicity -------------------------------------------------------

  def test_the_whole_decision_costs_one_round_trip
    spy = Wurk::Test::CommandSpy.new(@pool)
    Thread.current[:wurk_capsule] = spy
    Wurk::Throttle.admit(job(jid: jid('a')), slot: SLOT)
    Thread.current[:wurk_capsule] = nil

    assert_equal 1, spy.count, 'SET NX then read-the-winner is one script, not two commands'
  ensure
    Thread.current[:wurk_capsule] = nil
  end

  # Concurrent producers on separate connections. Aligning the slot in Ruby
  # instead of in Redis is what this would catch: two clocks a second apart
  # either side of a boundary would compute different indices and both win.
  def test_concurrent_producers_admit_exactly_one
    pool = Wurk::RedisPool.new(size: 8, url: Wurk::Test.redis_url, name: 'throttle-race')
    barrier = Queue.new
    threads = Array.new(8) do |i|
      Thread.new do
        barrier.pop
        Wurk::Throttle.admit(job(jid: jid(i)), slot: SLOT, pool: pool)
      end
    end
    8.times { barrier << :go }
    outcomes = threads.map(&:value)

    assert_equal 1, outcomes.count(&:admitted?)
    assert_equal 1, slot_keys.size
  ensure
    pool&.disconnect!
  end

  # Every loser must be told the same winner, not a partial view of the race.
  def test_every_loser_names_the_one_winner
    winner = Wurk::Throttle.admit(job(jid: jid('a')), slot: SLOT)
    losers = 3.times.map { |i| Wurk::Throttle.admit(job(jid: jid(i)), slot: SLOT) }

    assert_equal [winner.jid], losers.map(&:jid).uniq
  end

  # --- validation ------------------------------------------------------

  # A slot boundary is a wall-clock landmark every producer has to land on
  # identically, and EX cannot express a fraction of a second.
  def test_slot_must_be_a_positive_whole_number_of_seconds
    [0, -1, nil, 'sixty', 1.5, Float::INFINITY].each do |bad|
      error = assert_raises(ArgumentError, "slot: #{bad.inspect} must be refused") do
        Wurk::Throttle.admit(job, slot: bad)
      end

      assert_match(/slot/, error.message)
    end
  end

  def test_a_whole_float_is_a_valid_slot
    assert_predicate Wurk::Throttle.admit(job(jid: jid('a')), slot: 60.0), :admitted?
  end

  # The slot stores the jid and hands it back as the answer to "who won", so a
  # payload without one turns every later drop into an unattributable one.
  def test_a_job_without_a_jid_is_refused
    [nil, ''].each do |bad|
      assert_raises(ArgumentError) { Wurk::Throttle.admit(job(jid: bad), slot: SLOT) }
    end
  end

  private

  def jid(suffix) = "#{object_id}-#{suffix}"

  def job(klass: nil, args: [1], queue: nil, jid: 'seed', **extra)
    { 'class' => klass || @class_name, 'args' => args, 'queue' => queue || @queue,
      'jid' => jid, 'created_at' => 1_700_000_000.0 }.merge(extra.transform_keys(&:to_s))
  end

  # Fresh `job_id` on every call: raw args like these never repeat, which is
  # exactly why the digest has to narrow to the inner job.
  def active_job_payload(job_id)
    { 'class' => 'Sidekiq::ActiveJob::Wrapper', 'queue' => @queue, 'jid' => job_id,
      'args' => [{ 'job_class' => @class_name, 'job_id' => job_id, 'arguments' => [1],
                   'enqueued_at' => job_id, 'executions' => 0 }] }
  end

  # Every live slot key for this test's identity. The prefix carries the class
  # name's namespace through the digest, so the glob cannot see a sibling
  # suite's keys.
  def slot_keys(payload = job)
    @pool.with { |conn| conn.call('KEYS', "#{Wurk::Throttle.key_prefix_for(payload)}:*") }
  end

  # A worker class that narrows its identity to the first arg, defined and
  # removed inside the block so the constant never leaks to a sibling test.
  def with_narrowing_worker
    name = "ThrottleNarrowed#{object_id}"
    Object.const_set(name, Class.new do
      def self.sidekiq_unique_context(job) = job['args'].first
    end)
    yield name
  ensure
    Object.send(:remove_const, name) if Object.const_defined?(name)
  end
end
