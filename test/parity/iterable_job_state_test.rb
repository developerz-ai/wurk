# frozen_string_literal: true

require_relative '../test_helper'

# Parity oracle for the IterableJob iteration-state schema: the `it-<jid>`
# HASH and the fields written through public IterableJob / Client behavior.
#
# Spec: docs/target/sidekiq-free.md §1.5 (lines 90-104: key `it-<jid>`, type
# HASH; fields ex = execution count (int), c = cursor (JSON string), rt =
# runtime accumulated (float seconds), cancelled = timestamp (int) if
# cancelled), §6.4 (Sidekiq::IterableJob: iteration_key is "it-#{jid}",
# cancel! sets the hash field, Sidekiq::Job::Interrupted is the public
# interrupt signal), §7 (Sidekiq::Client#cancel!(jid) marks an IterableJob
# cancelled and returns the timestamp).
#
# Cursor convention, from Sidekiq::Job::Iterable#iterate_with_enumerator and
# its enumerators: the cursor yielded beside an item is that item's own
# position (`array_enumerator` yields the index and drops that many on
# resume), and it is recorded before the item runs. A run interrupted between
# items resumes at the first item not yet run; one that stops inside an item
# resumes with that item. This file used to pin enumerators yielding the NEXT
# position, under which a clean interrupt re-ran the last completed item.
#
# Upstream revision: test/parity/.sidekiq_sha.
#
# Retention (any TTL/expiry on the `it-<jid>` key) is deliberately out of
# scope for this oracle: the documented schema asserted here is the key, its
# type, and its fields.
class IterableJobStateParityTest < Wurk::Test::UnitCase
  parallelize_me!

  # Interrupts mid-enumerator on demand, so an interrupted run leaves its
  # state HASH behind for HGETALL inspection and a fresh instance can resume
  # the same jid from the persisted cursor.
  class ResumableIterable
    include Sidekiq::IterableJob

    attr_accessor :interrupt_at

    def seen
      @seen ||= []
    end

    def build_enumerator(*, cursor:)
      start = cursor || 0
      Enumerator.new { |y| start.upto(3) { |i| y << [i, i] } }
    end

    def each_iteration(item, *)
      seen << item
      raise Sidekiq::Job::Interrupted if item == interrupt_at
    end
  end

  # Elapsed time this oracle controls: every TimedIterable iteration charges
  # ITERATION_SECONDS to a scripted CLOCK_MONOTONIC, so an execution's runtime
  # is a known constant and the stored `rt` can be asserted against an exact
  # sum (§1.5: runtime accumulated) rather than a `>= 0` bound that a
  # reset-per-execution or always-zero writer would also pass.
  ITERATION_SECONDS = 0.5
  RT_DELTA = 1e-9

  # Monotonic stand-in whose #advance is the only way time moves.
  class ScriptedClock
    def initialize(start = 0.0)
      @now = start.to_f
    end

    attr_reader :now

    def advance(seconds)
      @now += seconds
    end
  end

  # ResumableIterable whose iterations consume scripted monotonic time.
  class TimedIterable < ResumableIterable
    class << self
      attr_accessor :clock
    end

    def each_iteration(item, *)
      self.class.clock.advance(ITERATION_SECONDS)
      super
    end
  end

  # --- iteration_key (§6.4) --------------------------------------------

  def test_iteration_key_is_it_prefixed_jid
    worker = ResumableIterable.new
    worker.jid = 'parity-deadbeef'

    assert_equal 'it-parity-deadbeef', worker.iteration_key
  end

  # --- Sidekiq::Client#cancel! (§7, §1.5 cancelled field) ---------------

  def test_client_cancel_creates_hash_with_cancelled_timestamp
    jid = random_jid

    begin
      ts = Sidekiq::Client.new.cancel!(jid)

      assert_kind_of Integer, ts, 'cancel! returns the timestamp'
      assert_in_delta Time.now.to_i, ts, 60, 'timestamp is epoch seconds'
      assert_equal 'hash', redis('TYPE', "it-#{jid}")
      assert_equal ts.to_s, redis('HGET', "it-#{jid}", 'cancelled').to_s
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # --- IterableJob#cancel! (§6.4: sets hash field) -----------------------

  def test_iterable_cancel_writes_cancelled_timestamp_field
    jid = random_jid
    worker = ResumableIterable.new
    worker.jid = jid

    begin
      ts = worker.cancel!

      assert_kind_of Integer, ts
      assert_equal ts.to_s, redis('HGET', "it-#{jid}", 'cancelled').to_s
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # --- ex / c / rt schema on an interrupted run (§1.5) -------------------

  def test_interrupted_run_persists_ex_c_rt_fields
    jid = random_jid
    worker = ResumableIterable.new
    worker.jid = jid
    worker.interrupt_at = 2

    begin
      assert_raises(Sidekiq::Job::Interrupted) { worker.perform }
      assert_equal [0, 1, 2], worker.seen

      assert_equal 'hash', redis('TYPE', "it-#{jid}")
      hash = state_hash(jid)

      # ex: execution count (int) — one execution has run.
      assert_match(/\A\d+\z/, hash['ex'].to_s, 'ex is an int')
      assert_equal '1', hash['ex']

      # c: cursor (JSON string) — round-trips through JSON to the cursor of
      # the item in flight (item 2 raised, so the resume starts with it).
      assert_equal 2, JSON.parse(hash['c'])

      # rt: runtime accumulated (float seconds).
      assert_match(/\./, hash['rt'].to_s, 'rt is a float string')
      assert_operator Float(hash['rt']), :>=, 0.0

      # cancelled: present only "if cancelled" — this run was interrupted,
      # not cancelled.
      refute hash.key?('cancelled')
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # --- resumed run continues from the persisted cursor (§1.5 c / rt) ------

  def test_resumed_run_continues_from_persisted_cursor
    jid = random_jid
    clock = ScriptedClock.new(1_000.0)
    TimedIterable.clock = clock
    first = TimedIterable.new
    first.jid = jid
    first.interrupt_at = 2

    begin
      with_monotonic_clock(clock) do
        assert_raises(Sidekiq::Job::Interrupted) { first.perform }
      end

      # rt: the first execution charged exactly its 3 iterations (§1.5 rt is
      # runtime accumulated in float seconds).
      assert_in_delta 3 * ITERATION_SECONDS, Float(state_hash(jid)['rt']), RT_DELTA,
                      'first execution stores its own controlled runtime'

      resumed = TimedIterable.new
      resumed.jid = jid
      resumed.interrupt_at = 3

      with_monotonic_clock(clock) do
        assert_raises(Sidekiq::Job::Interrupted) { resumed.perform }
      end

      # The resumed run picked up at the persisted cursor (2), not from 0.
      assert_equal [2, 3], resumed.seen

      hash = state_hash(jid)

      # ex: execution count (int) — a second execution of the same jid.
      assert_equal '2', hash['ex']

      # c: cursor (JSON string) — the interrupt came inside item 3.
      assert_equal 3, JSON.parse(hash['c'])

      # rt: accumulated ACROSS executions — exactly first (3 iterations) +
      # second (2 iterations). Elapsed time is controlled by the scripted
      # clock, so a writer that reset `rt` per execution (would store 1.0)
      # or always wrote 0.0 cannot pass here.
      assert_in_delta 5 * ITERATION_SECONDS, Float(hash['rt']), RT_DELTA,
                      'rt must accumulate across executions'
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # --- a clean interrupt resumes after the last completed item -----------

  # `interrupted?` reads `_context.stopping?`, as the Processor provides it.
  class StoppingAfter
    def initialize(checks)
      @checks = checks
    end

    def stopping?
      (@checks -= 1).negative?
    end
  end

  class LetterIterable
    include Sidekiq::IterableJob

    def seen
      @seen ||= []
    end

    def build_enumerator(*, cursor:)
      array_enumerator(%w[a b c d], cursor: cursor)
    end

    def each_iteration(item, *)
      seen << item
    end
  end

  def test_run_interrupted_between_items_resumes_at_the_next_one
    jid = random_jid
    first = LetterIterable.new
    first.jid = jid
    first._context = StoppingAfter.new(2)

    begin
      assert_raises(Sidekiq::Job::Interrupted) { first.perform }
      assert_equal %w[a b], first.seen
      assert_equal 2, JSON.parse(state_hash(jid)['c']), 'the cursor is the index of the first item not run'

      resumed = LetterIterable.new
      resumed.jid = jid
      resumed.perform

      assert_equal %w[c d], resumed.seen
      assert_equal 0, redis('EXISTS', "it-#{jid}")
    ensure
      cleanup_iteration_key(jid)
    end
  end

  # State as Sidekiq leaves it for the same interruption: Wurk resumes it at
  # the same item, so a job can cross a cutover mid-iteration.
  def test_state_written_by_sidekiq_resumes_at_its_cursor
    jid = random_jid
    redis('HSET', "it-#{jid}", 'ex', '1', 'c', '2', 'rt', '0.25')
    worker = LetterIterable.new
    worker.jid = jid

    begin
      worker.perform

      assert_equal %w[c d], worker.seen
    ensure
      cleanup_iteration_key(jid)
    end
  end

  class FailingIterable < LetterIterable
    def each_iteration(item, *)
      super
      raise 'boom' if item == 'b'
    end
  end

  # Upstream flushes on any exception out of an iteration, so the retry
  # starts with the item that raised.
  def test_an_item_that_raises_is_where_the_retry_starts
    jid = random_jid
    worker = FailingIterable.new
    worker.jid = jid

    begin
      assert_raises(RuntimeError) { worker.perform }
      assert_equal 1, JSON.parse(state_hash(jid)['c'])
    ensure
      cleanup_iteration_key(jid)
    end
  end

  def test_scripted_monotonic_clock_is_thread_local_and_restored_after_return
    original = Process.method(:clock_gettime)
    clock = ScriptedClock.new(-1_000.0)
    ready = Queue.new
    worker = Thread.new do
      ready.pop
      before = original.call(Process::CLOCK_MONOTONIC)
      reading = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      after = original.call(Process::CLOCK_MONOTONIC)
      [before, reading, after]
    end

    begin
      with_monotonic_clock(clock) do
        assert_in_delta(-1_000.0, Process.clock_gettime(Process::CLOCK_MONOTONIC), RT_DELTA)
        clock.advance(ITERATION_SECONDS)
        ready << true
        before, reading, after = worker.value

        assert_operator reading, :>=, before
        assert_operator reading, :<=, after
        2.times do
          assert_in_delta(-999.5, Process.clock_gettime(Process::CLOCK_MONOTONIC), RT_DELTA)
        end
        clock.advance(2.0)

        assert_in_delta(-997.5, Process.clock_gettime(Process::CLOCK_MONOTONIC), RT_DELTA)
      end

      assert_equal original, Process.method(:clock_gettime)
      before = original.call(Process::CLOCK_MONOTONIC)
      reading = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_operator reading, :>=, before
      assert_operator reading, :<=, original.call(Process::CLOCK_MONOTONIC)
    ensure
      worker.kill
      worker.join
    end
  end

  def test_scripted_monotonic_clock_delegates_other_clocks_and_units
    original = Process.method(:clock_gettime)

    with_monotonic_clock(ScriptedClock.new(-1_000.0)) do
      [[Process::CLOCK_MONOTONIC, :nanosecond],
       [Process::CLOCK_REALTIME],
       [Process::CLOCK_REALTIME, :nanosecond]].each do |args|
        before = original.call(*args)
        reading = Process.clock_gettime(*args)
        after = original.call(*args)

        assert_equal before.class, reading.class
        assert_operator reading, :>=, before
        assert_operator reading, :<=, after
      end
    end
  end

  def test_scripted_monotonic_clock_is_restored_after_exception
    original = Process.method(:clock_gettime)
    error = RuntimeError.new('scripted block failed')

    raised = assert_raises(RuntimeError) do
      with_monotonic_clock(ScriptedClock.new(-1_000.0)) { raise error }
    end

    assert_same error, raised
    assert_equal original, Process.method(:clock_gettime)
    before = original.call(Process::CLOCK_MONOTONIC)
    reading = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_operator reading, :>=, before
    assert_operator reading, :<=, original.call(Process::CLOCK_MONOTONIC)
  end

  private

  # Route only the invoking thread's bare CLOCK_MONOTONIC reads to `clock`
  # (iterable_job.rb's reset_run_state / flush_state). Other threads and the
  # unit-arg / REALTIME reads behind flush and cancellation keep real cadence.
  def with_monotonic_clock(clock)
    original = Process.method(:clock_gettime)
    owner = Thread.current
    Process.define_singleton_method(:clock_gettime) do |clock_id, unit = nil|
      if Thread.current.equal?(owner) && clock_id == Process::CLOCK_MONOTONIC && unit.nil?
        clock.now
      elsif unit.nil?
        original.call(clock_id)
      else
        original.call(clock_id, unit)
      end
    end
    yield
  ensure
    Process.define_singleton_method(:clock_gettime, original)
  end

  def random_jid
    @_jid_counter ||= 0
    @_jid_counter += 1
    "parity-it-#{Process.pid}-#{object_id}-#{@_jid_counter}"
  end

  def redis(*cmd)
    Wurk.redis { |c| c.call(*cmd) }
  end

  def state_hash(jid)
    raw = redis('HGETALL', "it-#{jid}")
    raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
  end

  def cleanup_iteration_key(jid)
    redis('DEL', "it-#{jid}")
  end
end
