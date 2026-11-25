# frozen_string_literal: true

require_relative 'component'
require_relative 'processor'

module Wurk
  # One per Capsule. Lives inside each forked child and owns the Processor
  # pool. Replaces dead processors on the fly (replace-on-die), forwards
  # the quiet/stop signals received by the Swarm to its processors, and
  # ensures the in-flight UnitsOfWork of threads it kills are bulk_requeued.
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

    # `shutdown:` is the owning Launcher's process-wide shutdown request,
    # invoked when concurrency can no longer be held (see #processor_result).
    # Injected rather than reached for: only the entry point knows how this
    # process exits — a swarm child / standalone CLI re-delivers TERM to itself
    # so the installed trap drives the normal drain, while embedded mode owns
    # no traps and must stop the launcher in place. A Manager built without an
    # owner (Sidekiq's `Manager.new(capsule)` arity, kept for the alias) has no
    # route to take, so it only reports.
    def initialize(capsule, shutdown: nil)
      @config = @capsule = capsule
      @count = capsule.concurrency
      raise ArgumentError, "Concurrency of #{@count} is not supported" if @count < 1

      @done = false
      @shutdown = shutdown
      @workers = Set.new
      @plock = ::Mutex.new
      @count.times do
        @workers << Processor.new(@capsule, &method(:processor_result))
      end
    end

    def start
      workers_snapshot.each(&:start)
    end

    def quiet
      return if @done

      snapshot = @plock.synchronize do
        @done = true
        @workers.dup
      end
      # Halt fetching for the whole capsule up front: the shared fetcher's drain
      # flag makes retrieve_work return nil immediately, so a processor can't pull
      # a fresh job between quiet and its own terminate taking effect. Safe-nav
      # covers a quiet that lands before Capsule#prepare! materializes the fetcher
      # (e.g. a signal-driven quiet on a partially-booted launcher) — nothing is
      # fetching yet, so there is nothing to halt.
      #
      # Also what keeps a quieted capsule off the global-concurrency ledger: it
      # takes no further slots, and Fetcher#terminate flushes the ACKs it is
      # holding, each of which carries the release of the slot its job ran under
      # (Fetcher::Reliable::UnitOfWork#release_slot_in). What is left is exactly
      # the slots the still-draining jobs are using — a quiet process holds
      # capacity it is spending, never capacity it is only reserving.
      capsule.fetcher&.terminate
      logger.info { "Terminating quiet threads for #{capsule.name} capsule" }
      snapshot.each(&:terminate)
    end

    # Graceful shutdown: quiet first, then poll for workers to clear.
    # If the deadline elapses with workers still alive we fall through to
    # hard_shutdown, which kills their threads and bulk_requeues their UoWs.
    def stop(deadline)
      quiet
      # Lifecycle hooks (e.g. :quiet) can be async; give them a tick to settle
      # before we start polling. Matches Sidekiq's PAUSE_TIME behavior.
      sleep PAUSE_TIME
      return if workers_empty?

      logger.info { 'Pausing to allow jobs to finish...' }
      wait_for(deadline) { workers_empty? }
      return if workers_empty?

      hard_shutdown
    ensure
      # After the drain, not in #quiet: a quieted capsule still has in-flight
      # jobs, and a bound shorter than the drain budget has to fire before
      # shutdown wins. Ahead of capsule.stop so no scan can raise into a thread
      # once the capsule has released what that thread was holding.
      capsule.watchdog&.terminate
      capsule.stop
    end

    def stopped?
      @done
    end

    # Processor#run callback: invoked when a Processor thread exits, whether
    # cleanly or via raised exception. Removes the dead processor from the
    # pool and (unless we're already stopping) spawns a replacement so the
    # capsule's concurrency stays constant. If the replacement itself can't be
    # spawned, ask the owner to shut this process down (the swarm respawns it at
    # full concurrency) rather than silently dropping a worker for the life of
    # the process. Snapshot under @plock; start the replacement — a
    # side effect — outside the lock.
    def processor_result(processor, _reason = nil)
      replacement = @plock.synchronize do
        @workers.delete(processor)
        unless @done
          p = Processor.new(@capsule, &method(:processor_result))
          @workers << p
          p
        end
      end
      replacement&.start
    rescue StandardError => e
      # Replacement spawn failed (e.g. ThreadError at the OS thread limit).
      # Silently running one Processor short for the life of the process is
      # invisible degradation, so take the process down (the swarm respawns it
      # at full concurrency) — but through the owner's TERM path, never
      # `Thread.main.raise`: that raise unwound straight past Manager#stop, so
      # the in-flight UnitsOfWork were never bulk_requeued and each one waited
      # out a full reaper interval, and in embedded mode it killed the host's
      # main thread instead of just the worker. Non-blocking by contract — we
      # are on the dying Processor's own thread, which the drain will kill.
      @capsule.config.handle_exception(e, { context: 'Manager could not replace a dead Processor' })
      @shutdown&.call
    end

    # How long killed threads may take to unwind before what is left of their jobs
    # is requeued anyway, and how long the process gives the last of them after
    # that. Inside what the Launcher and the Swarm allow a Manager past its
    # deadline (Launcher::TEARDOWN_GRACE, the shortest).
    UNWIND_GRACE = 2
    STRAGGLER_GRACE = 1
    UNWIND_POLL = 0.02
    private_constant :UNWIND_POLL

    # Reached when the deadline expired with workers still busy: raise
    # Wurk::Shutdown into each, and move every unfinished job from the private list
    # back to the public queue (Reliable#bulk_requeue), where it runs again from the
    # top (Sidekiq's at-least-once contract), as soon as its own thread has ended.
    # What has not ended within UNWIND_GRACE is requeued under its running thread.
    #
    # In that order because a requeued job is running elsewhere within a
    # millisecond, and an unwinding run still has `ensure` blocks to go: it
    # releases limiter slots, saves an iteration cursor, rolls back. A run past its
    # requeue does all that beside the run that replaced it. Waiting costs no job:
    # until the move it sits in the private list, which a SIGKILL leaves for the
    # reaper. A fetcher with no private list has nothing holding the payload
    # meanwhile, so its jobs go back first.
    #
    # `job` is read off another thread and before the kill, after which a
    # Processor drops it. One that had finished, or was booking its retry, when the
    # interrupt was sent ACKs it (Processor#cut_short?), and bulk_requeue's guard
    # skips the RPUSH on a miss.
    #
    # Every processor is killed even when a requeue raises (Redis down mid-drain):
    # embedded, the host keeps living after #stop, and those threads would carry
    # on executing jobs over pools the launcher is about to reset. The requeue
    # error still propagates to the caller, which reports it.
    def hard_shutdown
      cleanup = workers_snapshot
      return if cleanup.empty?

      units = cleanup.to_h { |worker| [worker, worker.job] }.compact
      if capsule.fetcher.is_a?(Fetcher::Reliable)
        unwind_then_requeue(cleanup, units)
      else
        requeue_then_kill(cleanup, units.values)
      end
    ensure
      # The caller typically `exit`s immediately after we return; give threads
      # that outlived the requeue a brief window to run their `ensure` blocks.
      wait_for_unwind(cleanup, STRAGGLER_GRACE) if cleanup
    end

    private

    def unwind_then_requeue(cleanup, units)
      interrupt(cleanup, units.values)
      requeue_as_they_end(units)
    ensure
      # Also flushes the ACKs of the threads that ended, with nothing left to move.
      capsule.fetcher.bulk_requeue(units.values)
    end

    # Drops from `units` what it has put back. A refused requeue leaves the rest to
    # the caller's, at the end of the wait: one more try, not one every poll.
    def requeue_as_they_end(units)
      deadline = monotonic + UNWIND_GRACE
      until units.empty? || monotonic >= deadline
        ended = units.reject { |worker, _| running?(worker) }
        return wait_for_unwind(units.keys, deadline - monotonic) unless requeued?(ended.values)

        ended.each_key { |worker| units.delete(worker) }
        sleep UNWIND_POLL
      end
    end

    def requeued?(jobs)
      capsule.fetcher.bulk_requeue(jobs) if jobs.any?
      true
    rescue StandardError => e
      capsule.config.handle_exception(e, { context: 'Error requeueing a job interrupted by shutdown' })
      false
    end

    def requeue_then_kill(cleanup, jobs)
      # `&.` like #quiet: a TERM in the pre-prepare! window (traps install
      # before launcher.run) reaches here with no fetcher built yet.
      capsule.fetcher&.bulk_requeue(jobs)
    ensure
      interrupt(cleanup, jobs)
      wait_for_unwind(cleanup, UNWIND_GRACE)
    end

    def interrupt(cleanup, jobs)
      cleanup.each(&:kill)
      logger.warn { "Terminating #{cleanup.size} busy threads" }
      log_interrupted(jobs)
    end

    def running?(worker) = worker.thread&.alive?
    def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

    # Polled rather than joined: a join re-raises what ended the thread.
    def wait_for_unwind(cleanup, seconds)
      deadline = monotonic + seconds
      sleep UNWIND_POLL while cleanup.any? { |worker| running?(worker) } && monotonic < deadline
    end

    # One WARN per job a deploy cut short, because each one runs again from the
    # top (docs/idempotency.md) and the operator chasing a double side effect
    # needs its jid. Capped: a capsule can hold hundreds of threads.
    REQUEUE_LOG_LIMIT = 20
    private_constant :REQUEUE_LOG_LIMIT

    def log_interrupted(jobs)
      jobs.first(REQUEUE_LOG_LIMIT).each do |uow|
        logger.warn { "Interrupting #{describe_job(uow)}: past the shutdown deadline, it is requeued to run again" }
      end
      extra = jobs.size - REQUEUE_LOG_LIMIT
      logger.warn { "Interrupting #{extra} more in-flight jobs, which run again too" } if extra.positive?
    end

    # The payload is parsed here, off the hot path, because the fetcher never
    # parses. A plug-in fetcher's unit of work may carry something that is not
    # job JSON; it is named by its queue alone.
    def describe_job(uow)
      job = Wurk.load_json(uow.job)
      job = {} unless job.is_a?(::Hash)
      klass = job['wrapped'] || job['class']
      "#{klass} jid=#{job['jid']} queue=#{uow.queue_name}"
    rescue ::JSON::ParserError, ::TypeError
      "job queue=#{uow.queue_name}"
    end

    # The @workers Set is mutated from Processor threads (processor_result)
    # while the lifecycle methods read/iterate it from the manager thread.
    # Snapshot under @plock, then act on the copy outside the lock.
    def workers_snapshot
      @plock.synchronize { @workers.dup }
    end

    # Drained means "no processor thread is still running", not "the Set is
    # empty": a processor removes itself from @workers from inside its own
    # thread, so the two agree — except for a processor that was never started
    # (a launcher that raised mid-boot and rolled back). That one holds no
    # thread and nothing will ever remove it, so an emptiness test would make
    # #stop poll out the entire shutdown deadline waiting on a worker that
    # never ran.
    def workers_empty?
      @plock.synchronize { @workers.none? { |w| w.thread&.alive? } }
    end

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
