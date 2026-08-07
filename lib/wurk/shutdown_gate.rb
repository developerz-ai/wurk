# frozen_string_literal: true

module Wurk
  # The two rules a process teardown obeys: it runs exactly once, and it never
  # waits on a thread without a bound. Same reason TimerLoop exists — the
  # mutex/clock dance was going to be hand-rolled in the caller, so it lives in
  # one place with a name instead.
  #
  # A worker process can have several shutdown requests in flight at once — a
  # dashboard-queued TERM, an embedded host calling `stop`, a Manager that can
  # no longer hold its concurrency — and running the teardown twice double-fires
  # the `:exit` hooks and tears the Redis pool down under the thread still using
  # it.
  #
  #   @gate = Wurk::ShutdownGate.new
  #   def stop = @gate.run { ...teardown... }
  #
  # The first caller runs the block; the rest block until it returns and then get
  # nil. `Queue#close` releases every waiter at once and makes every later call
  # return immediately, so a `stop` landing after the teardown finished is a
  # no-op rather than a second one.
  #
  # The lock is only ever held for the bookkeeping, never across the teardown —
  # a caller that must not block (a dying Processor thread, the heartbeat the
  # teardown is about to join) has to be able to ask for a shutdown that is
  # already under way without deadlocking against it.
  class ShutdownGate
    def initialize
      @mutex = ::Mutex.new
      @owner = nil
      @runner = nil
      @done = ::Queue.new
    end

    def run
      return await unless claim

      begin
        yield
      ensure
        @done.close
      end
    end

    # Memoizes the one background thread a caller uses to reach #run from
    # somewhere it cannot block. Spawned once: a second request rides the first
    # teardown instead of leaving another unreferenced one running behind it.
    def runner
      @mutex.synchronize { @runner ||= yield }
    end

    # Join every thread inside one shared monotonic `budget` (an absolute
    # CLOCK_MONOTONIC instant), so N wedged threads cost the budget once rather
    # than N times. A non-positive remainder polls without waiting, which is the
    # right answer once the budget is spent: the straggler is left to the process
    # exit rather than holding the whole teardown open behind it.
    def join_within(threads, budget)
      threads.each { |t| t.join([budget - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC), 0].max) }
    end

    private

    def claim
      @mutex.synchronize do
        return false if @owner

        @owner = Thread.current
        true
      end
    end

    # The owner re-entering (a `:shutdown` hook that calls `stop`) cannot wait on
    # a teardown it is inside of, so it returns instead of deadlocking.
    def await
      @done.pop unless @mutex.synchronize { @owner } == Thread.current
      nil
    end
  end
end
