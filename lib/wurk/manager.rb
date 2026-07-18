# frozen_string_literal: true

require_relative 'component'
require_relative 'processor'

module Wurk
  # One per Capsule. Lives inside each forked child and owns the Processor
  # pool. Replaces dead processors on the fly (replace-on-die), forwards
  # the quiet/stop signals received by the Swarm to its processors, and
  # ensures in-flight UnitsOfWork are bulk_requeued before threads are killed.
  #
  # Lifecycle:
  #   * `start`         — spawn each processor thread.
  #   * `quiet`         — stop fetching; in-flight jobs run to completion.
  #   * `stop(deadline)`— quiet + wait for drain; hard_shutdown on timeout.
  #
  # Spec: docs/target/sidekiq-free.md §13.
  class Manager
    include Component

    # 0.1 in TTY mode so interactive shutdown feels snappy; 0.5 in
    # production so the supervisor isn't spinning while threads drain.
    PAUSE_TIME = $stdout.tty? ? 0.1 : 0.5

    attr_reader :workers, :capsule

    def initialize(capsule)
      @config = @capsule = capsule
      @count = capsule.concurrency
      raise ArgumentError, "Concurrency of #{@count} is not supported" if @count < 1

      @done = false
      @workers = Set.new
      @plock = ::Mutex.new
      @count.times do
        @workers << Processor.new(@capsule, &method(:processor_result))
      end
    end

    def start
      @workers.each(&:start)
    end

    def quiet
      return if @done

      @done = true
      logger.info { "Terminating quiet threads for #{capsule.name} capsule" }
      @workers.each(&:terminate)
    end

    # Graceful shutdown: quiet first, then poll for workers to clear.
    # If the deadline elapses with workers still alive we fall through to
    # hard_shutdown, which bulk_requeues their UoWs before killing threads.
    def stop(deadline)
      quiet
      # Lifecycle hooks (e.g. :quiet) can be async; give them a tick to settle
      # before we start polling. Matches Sidekiq's PAUSE_TIME behavior.
      sleep PAUSE_TIME
      return if @workers.empty?

      logger.info { 'Pausing to allow jobs to finish...' }
      wait_for(deadline) { @workers.empty? }
      return if @workers.empty?

      hard_shutdown
    ensure
      capsule.stop
    end

    def stopped?
      @done
    end

    # Processor#run callback: invoked when a Processor thread exits, whether
    # cleanly or via raised exception. Removes the dead processor from the
    # pool and (unless we're already stopping) spawns a replacement so the
    # capsule's concurrency stays constant.
    def processor_result(processor, _reason = nil)
      @plock.synchronize do
        @workers.delete(processor)
        unless @done
          p = Processor.new(@capsule, &method(:processor_result))
          @workers << p
          p.start
        end
      end
    end

    # Reached when the deadline expired with workers still busy. Atomically
    # move their in-flight UoWs private→public (Reliable#bulk_requeue) BEFORE
    # raising Wurk::Shutdown into the threads, so a job killed mid-perform is
    # re-run once (Sidekiq's at-least-once contract). `job` is read off another
    # thread, so a Processor can ACK between this map and the requeue — but
    # bulk_requeue's LREM guard skips the RPUSH on a miss, so a job that
    # finished in that window is not resurrected onto the public queue.
    def hard_shutdown # rubocop:disable Metrics/AbcSize
      cleanup = nil
      @plock.synchronize do
        cleanup = @workers.dup
      end

      if cleanup.any?
        jobs = cleanup.map(&:job).compact

        logger.warn { "Terminating #{cleanup.size} busy threads" }
        logger.debug { "Jobs still in progress #{jobs.inspect}" }

        capsule.fetcher.bulk_requeue(jobs)
      end

      cleanup.each(&:kill)

      # The caller typically `exit`s immediately after we return; give
      # threads a brief window to run their `ensure` blocks.
      deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 3
      wait_for(deadline) { @workers.empty? }
    end

    private

    # Polls `condblock` until it returns true or the monotonic deadline
    # passes. The PAUSE_TIME floor stops us from spinning when only a few
    # milliseconds remain.
    def wait_for(deadline)
      remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      while remaining > PAUSE_TIME
        return if yield

        sleep PAUSE_TIME
        remaining = deadline - ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
