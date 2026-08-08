# frozen_string_literal: true

require_relative 'component'
require_relative 'timer_loop'

module Wurk
  # One timer thread per Capsule — so one per Manager — that cuts jobs which
  # outlive a bound. `#watch` arms a bound around a block; once it passes, this
  # thread raises the caller's exception into the thread that armed it. Soft by
  # construction: an exception the job can rescue and the retry layer can book,
  # never `Thread#kill`.
  #
  # Not stdlib `Timeout`, which since Ruby 3.1 also runs one shared monitor
  # thread — that half of the folklore is out of date. What it still doesn't do
  # is contain its own raise: `Timeout::Request#interrupt` calls `Thread#raise`
  # with no interrupt mask, so a bound that wins the race against the block
  # returning lands at whatever checkpoint the thread reaches next — inside a
  # Processor, the ACK or the next job. Its own docs tell every caller to
  # hand-roll the `handle_interrupt` sandwich that avoids this; `#watch` writes
  # it once, for every bounded job. It is also ~1.5x cheaper per call
  # (08-watchdog-measurement.md in the slice plan) and accepts a bound that has
  # already passed, which `Timeout.timeout` rejects outright — an absolute
  # deadline read off an old payload is exactly that.
  #
  # Nothing bounded, nothing running: the thread is spawned by the first
  # `#watch`, so a process whose jobs declare no bound never has one. The
  # Capsule holds this like it holds the fetcher; the Manager drives its
  # lifecycle (Manager#stop, not #quiet — a quieted process still has in-flight
  # jobs, and a bound shorter than the drain budget must still fire).
  class Watchdog
    include Component

    # Scan cadence, and therefore the overshoot: a bound fires somewhere in
    # [deadline, deadline + SCAN_INTERVAL). Job bounds are wall-clock seconds,
    # so 500ms of slack is invisible; waking at the nearest deadline instead
    # would buy precision nobody asked for and cost a signal on every arm.
    SCAN_INTERVAL = 0.5

    THREAD_NAME = 'watchdog'

    Entry = Struct.new(:thread, :at_ms, :exception, :message)
    private_constant :Entry

    def initialize(capsule, interval: SCAN_INTERVAL)
      @config = @capsule = capsule
      @timer = TimerLoop.new(interval)
      @lock = ::Mutex.new
      # Keyed by a counter, not by Thread or by the Entry itself: one job can
      # hold two bounds at once (a per-attempt `timeout` inside an absolute
      # `deadline`), and Struct identity is value equality, so twin entries
      # would collide.
      @armed = {}
      @seq = 0
      @thread = nil
    end

    # Runs the block with `seconds` of wall-clock on it. Still on this thread's
    # stack when that runs out → `exception` (a class, with an optional message)
    # is raised into it. A bound that already passed is not special-cased; it
    # fires on the next scan.
    #
    # The interrupt pair is the containment guarantee, and the whole reason this
    # exists instead of `Timeout.timeout`. `:never` on the outer scope means a
    # raise that wins the race against #disarm is delivered when that scope pops
    # — inside this method — instead of at whatever checkpoint the thread
    # reaches next, which by then can be the ACK, or the next job. `:immediate`
    # on the inner scope is what lets a wedged job be interrupted at all;
    # without it the outer mask would hold the raise until the block it is meant
    # to cut short returned on its own.
    def watch(seconds, exception, message = nil)
      bound_id = arm(seconds, exception, message)
      Thread.handle_interrupt(exception => :never) do
        Thread.handle_interrupt(exception => :immediate) { yield } # rubocop:disable Style/ExplicitBlockArgument
      ensure
        disarm(bound_id)
      end
    end

    # Idempotent, and a no-op when nothing was ever armed. Bounded join like
    # every other periodic component: a scan blocked on a raise must not hold
    # the process's shutdown open. The thread reference is deliberately kept on
    # a join timeout — a wedged scan stays tracked, so a later #watch returns it
    # rather than spawning a second one alongside it.
    def terminate
      @timer.terminate
      @lock.synchronize { @thread }&.join(TimerLoop::JOIN_TIMEOUT)
    end

    # The two assertable halves of "zero cost when unconfigured, nothing leaked
    # when used": no bound was ever armed → no thread; every armed bound is
    # retracted on every exit path → nothing accumulates.
    def running?
      thread = @lock.synchronize { @thread }
      !thread.nil? && thread.alive?
    end

    def size
      @lock.synchronize { @armed.size }
    end

    # Capsule doesn't define handle_exception (it's a Configuration method);
    # override Component's delegation so error handlers fire.
    def handle_exception(ex, ctx = {})
      @capsule.config.handle_exception(ex, ctx)
    end

    private

    def arm(seconds, exception, message)
      entry = Entry.new(Thread.current, mono_ms + (seconds * 1000).round, exception, message)
      @lock.synchronize do
        bound_id = (@seq += 1)
        @armed[bound_id] = entry
        spawn_scanner
        bound_id
      end
    end

    def disarm(bound_id)
      @lock.synchronize { @armed.delete(bound_id) }
    end

    # Under @lock so two jobs arming at once can't spawn two scanners, and so a
    # thread that died of an unhandled error (safe_thread reports and re-raises)
    # is replaced by the next #watch instead of leaving the capsule unguarded.
    # TimerLoop#reset clears a previous #terminate: an embedded host that boots
    # again reuses this object, and the fresh thread would otherwise see the
    # stale done flag and exit at once.
    def spawn_scanner
      return if @thread&.alive?

      @timer.reset
      @thread = safe_thread(THREAD_NAME) { @timer.run { tick } }
    end

    def tick
      due.each { |entry| interrupt(entry) }
    end

    # Entries are removed here, before the raise: a fired bound can't fire
    # twice, and #disarm has nothing left to do if the exception lands on it.
    # That removal is also what retracts a stranded bound — one armed by a
    # thread that then died, so no #disarm will ever reach it. No liveness check
    # guards the raise itself: `Thread#raise` into a dead thread is a documented
    # no-op, and it doesn't even build the exception first.
    def due
      now = mono_ms
      @lock.synchronize do
        expired = @armed.select { |_, entry| entry.at_ms <= now }
        expired.each_key { |bound_id| @armed.delete(bound_id) }
        expired.values
      end
    end

    # Per entry, not per scan: one exception class that can't be instantiated
    # must not swallow the bounds of every other job in the same pass, and must
    # not take the scanner down with it — its bound was already retracted, so
    # nothing would ever re-arm it.
    def interrupt(entry)
      entry.thread.raise(entry.exception, entry.message)
    rescue StandardError => e
      handle_exception(e, { context: THREAD_NAME })
    end
  end
end
