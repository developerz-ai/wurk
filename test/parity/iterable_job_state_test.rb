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
      Enumerator.new { |y| start.upto(3) { |i| y << [i, i + 1] } }
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

      # c: cursor (JSON string) — round-trips through JSON to the last
      # completed cursor (item 1 advanced the cursor to 2).
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

      # c: cursor (JSON string) — item 2 advanced the cursor to 3 before
      # the interrupt at item 3.
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

  private

  # Route the run loop's bare CLOCK_MONOTONIC reads (iterable_job.rb's
  # reset_run_state / flush_state) to `clock` for the block's duration.
  # Every other call passes through — the unit-arg and REALTIME reads behind
  # the 5s flush gate and the cancellation poll keep their real cadence.
  def with_monotonic_clock(clock)
    original = Process.method(:clock_gettime)
    Process.define_singleton_method(:clock_gettime) do |clock_id, unit = nil|
      if clock_id == Process::CLOCK_MONOTONIC && unit.nil?
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
