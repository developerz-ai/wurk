# frozen_string_literal: true

require_relative 'component'
require_relative 'context'
require_relative 'dead_set'
require_relative 'job_logger'
require_relative 'job_retry'
require_relative 'profiler'

module Wurk
  # Inside each Manager, N Processors run in parallel. Each owns one thread,
  # pulls a UnitOfWork from the capsule's fetcher, parses the payload, walks
  # the server middleware chain, invokes `perform`, then ACKs (retires the
  # payload from the per-process private list). The ACK is handed to the
  # fetcher, which pipelines it with the next fetch rather than spending a
  # round trip on it — #flush_acks covers the case where there is no next
  # fetch.
  #
  # Shutdown is two-stage:
  #   * `terminate` flips a flag; the run loop exits between jobs.
  #   * `kill` additionally raises `Wurk::Shutdown` into the thread so an
  #     in-flight perform unwinds. The current UoW is NOT acked, so the
  #     payload survives in the private list and is reclaimed on next boot.
  #
  # Spec: docs/target/sidekiq-free.md §14.
  class Processor
    include Component

    # Interrupt masks for the two `Thread.handle_interrupt` scopes every job
    # runs inside. Frozen constants rather than the inline literals they
    # replace: the mask never varies, and a literal allocated two Hashes per
    # job. Sidekiq hoists the same pair (processor.rb:161-164).
    IGNORE_SHUTDOWN_INTERRUPTS = { Wurk::Shutdown => :never }.freeze
    private_constant :IGNORE_SHUTDOWN_INTERRUPTS
    ALLOW_SHUTDOWN_INTERRUPTS = { Wurk::Shutdown => :immediate }.freeze
    private_constant :ALLOW_SHUTDOWN_INTERRUPTS

    # Stand-in for the default reloader, `proc { |&b| b.call }`. That default
    # is an identity wrapper, but a block param (`|&b|`) forces MRI to reify
    # the dispatch block into a Proc on every job just to call it straight
    # back; `yield` does not. Same contract, one less allocation per job.
    module IdentityReloader
      def self.call
        yield
      end
    end
    private_constant :IdentityReloader

    attr_reader :thread, :job, :capsule

    def initialize(capsule, &callback)
      @capsule = capsule
      @config = capsule
      @callback = callback
      @done = false
      @job = nil
      @thread = nil
      @reloader = resolve_reloader(capsule.config[:reloader])
      @job_logger = (capsule.config[:job_logger] || JobLogger).new(capsule.config)
      @retrier = JobRetry.new(capsule)
    end

    # Sidekiq surface — positional boolean to match the drop-in contract.
    def terminate(wait = false) # rubocop:disable Style/OptionalBooleanParameter
      @done = true
      return if @thread.nil?

      @thread.value if wait
    end

    # Hard-stop: flips the flag *and* unwinds the in-flight job by raising
    # Wurk::Shutdown into the worker thread. The UoW is intentionally not
    # acked — the payload remains in the private list and is reclaimed on
    # next boot via Reliable#bulk_requeue.
    def kill(wait = false) # rubocop:disable Style/OptionalBooleanParameter
      @done = true
      return if @thread.nil?

      @thread.raise ::Wurk::Shutdown
      @thread.value if wait
    end

    def stopping?
      @done
    end

    def start
      @thread ||= safe_thread("#{@capsule.name}/processor", &method(:run)) # rubocop:disable Naming/MemoizedInstanceVariableName
    end

    # Capsule doesn't define handle_exception (it's a Configuration method);
    # override Component's delegation so error handlers fire.
    def handle_exception(ex, ctx = {})
      @capsule.config.handle_exception(ex, ctx)
    end

    # Single iteration: fetch one UoW, process it. Public so tests can drive
    # the loop step-by-step without spawning a thread.
    def process_one
      @job = fetch
      process(@job) if @job
      @job = nil
    end

    # Thread-safe global counter. Heartbeat reads + resets these every beat
    # to publish per-process stats.
    class Counter
      def initialize
        @value = 0
        @lock = ::Mutex.new
      end

      def incr(amount = 1)
        @lock.synchronize { @value += amount }
      end

      def reset
        @lock.synchronize do
          val = @value
          @value = 0
          val
        end
      end
    end

    # tid → { queue:, payload:, run_at: } for every Processor currently
    # running a job. Read by Heartbeat each beat to publish into Redis.
    class SharedWorkState
      def initialize
        @work = {}
        @lock = ::Mutex.new
      end

      def set(tid, hash)
        @lock.synchronize { @work[tid] = hash }
      end

      def delete(tid)
        @lock.synchronize { @work.delete(tid) }
      end

      # RAII: publish for the duration of the block, always retract. The write
      # lives *inside* this method's ensure frame on purpose — with the `set`
      # one line above a `begin`, an async raise landing in that gap (a host
      # timeout's `Thread#raise`, say) escapes the ensure and strands the
      # entry for the life of the process: the payload String stays reachable
      # and every heartbeat reports the thread as busy.
      def track(tid, hash)
        set(tid, hash)
        yield
      ensure
        delete(tid)
      end

      def dup
        @lock.synchronize { @work.dup }
      end

      def size
        @lock.synchronize { @work.size }
      end

      def clear
        @lock.synchronize { @work.clear }
      end
    end

    PROCESSED  = Counter.new
    FAILURE    = Counter.new
    EXPIRED    = Counter.new
    WORK_STATE = SharedWorkState.new

    private

    # Only the untouched framework default is swapped out — a host-supplied
    # reloader (Rails wraps every job in `Rails.application.reloader`) is used
    # exactly as given. `equal?` against DEFAULTS is sound because
    # Configuration's deep-dup copies Hashes/Arrays only, so an unset
    # `:reloader` is still the very Proc object DEFAULTS holds.
    def resolve_reloader(configured)
      return IdentityReloader if configured.nil? || configured.equal?(Configuration::DEFAULTS[:reloader])

      configured
    end

    def run
      # Wurk.redis / Sidekiq.redis inside a job resolve the pool through this
      # thread-local, so a job running in a non-default capsule checks out of
      # its own capsule's pool (sized for its concurrency), not the default's.
      # Restored on the way out for a caller that drives #run on its own thread.
      outer_capsule = Thread.current[:wurk_capsule]
      Thread.current[:wurk_capsule] = @capsule
      begin
        process_one until @done
      ensure
        flush_acks
        Thread.current[:wurk_capsule] = outer_capsule
      end
      @callback&.call(self)
    rescue Wurk::Shutdown
      @callback&.call(self)
    rescue Exception => e # rubocop:disable Lint/RescueException
      # Sidekiq hands the error to the manager (processor.rb `@callback.call(
      # self, ex)`); reporting it here keeps it visible, and the re-raise ends
      # the thread so the Manager's replacement starts clean.
      handle_exception(e, { context: '!shutdown' })
      @callback&.call(self)
      raise
    end

    # The fetcher holds each finished job's LREM until a fetch can pipeline it
    # (Fetcher::Reliable#defer_ack). This thread has stopped fetching, so
    # nothing else will send the one it may still be holding — and a finished
    # job left in the private list is invisible to Manager#hard_shutdown's
    # in-flight list, so the next boot's reaper would run it a second time.
    #
    # Inside the loop's own ensure rather than the method's: the callback below
    # drops this Processor from the Manager's pool, which is what lets
    # Manager#stop return and close the capsule's Redis pool out from under us.
    # `respond_to?` because a config[:fetch_class] fetcher need not defer, and
    # the capsule has no fetcher at all if the launcher died before prepare!.
    def flush_acks
      fetcher = @capsule.fetcher
      fetcher.flush_pending_acks if fetcher.respond_to?(:flush_pending_acks)
    rescue StandardError => e
      handle_exception(e, { context: 'Error flushing pending acks' })
    end

    def fetch
      @capsule.fetcher.retrieve_work
    rescue Wurk::Shutdown
      nil
    rescue StandardError => e
      handle_exception(e, { context: 'Error fetching job' })
      sleep(1)
      nil
    end

    # The whole frame runs with Wurk::Shutdown deferred; only the perform
    # itself (#run_job) lets it in. Parsing a malformed payload writes it to
    # the morgue — a Redis round trip — and the ACK in the `ensure` is another:
    # a raise landing in either would take the job's global-concurrency slot
    # with it, or skip the ACK of a job that already finished. A Shutdown that
    # arrives while deferred is delivered when this frame returns, after the
    # outcome is booked.
    def process(uow)
      Thread.handle_interrupt(IGNORE_SHUTDOWN_INTERRUPTS) { process_deferred(uow) }
    end

    def process_deferred(uow)
      jobstr = uow.job
      queue  = uow.queue_name

      ack = false
      begin
        # A payload that would not parse is already in the morgue and has
        # nothing left to run, but it is still ACKed from here rather than from
        # #parse_or_kill: one cleanup path, so the slot is released exactly once
        # on that exit as on every other.
        job_hash = parse_or_kill(jobstr)
        run_job(uow, job_hash, queue, jobstr) if job_hash
        ack = true
      rescue Wurk::JobRetry::Skip
        # A middleware booked the outcome itself (Limiter::Rescheduled, the
        # interrupt handler's re-push, Encryption's dead routing) — not a
        # failure, so nothing to report.
        ack = true
      rescue Wurk::JobRetry::Handled => e
        ack = true
        report_job_failure(e, job_hash)
      rescue Wurk::Shutdown
        # Don't ack — UoW stays in private list and is reclaimed on reboot.
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Escaped the retry layer (its ZADD hit a Redis blip, a logger raised in
        # JobLogger#prepare): no retry was booked. This owner is alive, so the
        # reaper will never reclaim its private list — put the job back now or
        # it sits there until the process restarts.
        handle_exception(e, { context: 'Internal exception!', job: job_hash, jobstr: jobstr })
        requeue(uow)
      ensure
        # This frame is the one every exit path passes through, which is why a
        # global-concurrency slot is given back from here and nowhere else: a
        # clean return, a failure, a retry, `Handled`, the watchdog's async
        # raise for a timeout or a deadline, the shutdown raise. A release added
        # to any single arm above is a release the next arm forgets, and a
        # forgotten one strands cluster-wide capacity for the whole slot TTL.
        #
        # One call on either branch, never a release on its own line after the
        # ACK: the ACK carries the slot's ZREM in its own pipeline, and only the
        # paths that deliberately do not ACK — the shutdown and the requeue,
        # whose payload goes back to the queue for someone else to run —
        # release by themselves.
        if ack
          uow.acknowledge
        elsif uow.respond_to?(:release_slot)
          release_slot(uow)
        end
      end
    end

    # Sidekiq's contract (processor.rb, "Job raised exception"): every job
    # failure the retry layer handled reaches config.error_handlers once, with
    # the job's own exception — `Handled` is raised from inside the retry
    # layer's rescue, so its cause is what the job threw.
    def report_job_failure(handled, job_hash)
      handle_exception(handled.cause || handled, { context: 'Job raised exception', job: job_hash })
    end

    # Reported, never raised: we are already handling an internal error, and
    # a Redis that refused the retry ZADD may refuse this too — the job then
    # stays in the private list, which is where it was before this ran.
    def requeue(uow)
      uow.requeue
    rescue StandardError => e
      handle_exception(e, { context: 'Error requeueing a job after an internal exception' })
    end

    # The dispatch half of #process. Shutdown is deferred for the whole onion
    # (by #process) and allowed only around the perform itself, which is what
    # lets a job finish its middleware unwind before the raise lands.
    def run_job(uow, job_hash, queue, jobstr)
      # The fetcher never parses, so hand it the jid we just read: the ACK
      # retires this job's poison-pill recovery counter inside the round trip
      # it rides. A fetcher plugged in via `config[:fetch_class]` has no jid
      # slot and simply ACKs — the counter then ages out on its 72h TTL.
      uow.jid = job_hash['jid'] if uow.respond_to?(:jid=)

      dispatch(job_hash, queue, jobstr) do |instance|
        Thread.handle_interrupt(ALLOW_SHUTDOWN_INTERRUPTS) do
          execute_job(instance, job_hash, queue)
        end
      end
    end

    # Reported, never raised: this runs inside #process's ensure on the shutdown
    # path, where a raise would replace the Wurk::Shutdown that got us here and
    # skip the rest of the unwind. The hold ages out on its TTL regardless.
    def release_slot(uow)
      uow.release_slot
    rescue StandardError => e
      handle_exception(e, { context: 'Error releasing a queue slot' })
    end

    # Parse JSON; on failure send the raw payload to the dead set (ZADD +
    # trim, via the shared DeadSet#kill_raw so the malformed path caps the
    # morgue exactly like send_to_morgue does — spec §31.8/§31.9).
    # Returns nil to signal "no further processing" — the ACK that retires the
    # payload belongs to #process's ensure, which is the one cleanup path.
    def parse_or_kill(jobstr)
      Wurk.load_json(jobstr)
    rescue ::JSON::ParserError => e
      handle_exception(e, { context: 'Invalid JSON', jobstr: jobstr })
      DeadSet.new.kill_raw(jobstr)
      nil
    end

    # Wraps the actual perform in the dispatch onion: retrier.global →
    # logger.prepare → logger.call → stats → reloader → instantiate →
    # retrier.local → (yield to caller for middleware + perform). `prepare`
    # sits inside `global` (Sidekiq has it outside) so a logger that raises
    # there books a retry instead of escaping the retry layer.
    def dispatch(job_hash, queue, jobstr)
      @retrier.global(jobstr, queue) do
        @job_logger.prepare(job_hash) do
          @job_logger.call(job_hash, queue) do
            stats(jobstr, queue) do
              Wurk::Profiler.call(job_hash) do
                @reloader.call do
                  instance = build_instance(job_hash)
                  @retrier.local(instance, jobstr, queue) do
                    yield instance
                  end
                end
              end
            end
          end
        end
      end
    end

    # Instantiate the worker and wire its per-job context. Extracted from
    # dispatch so the dispatch onion stays readable.
    def build_instance(job_hash)
      instance = Object.const_get(job_hash['class']).new
      instance.jid = job_hash['jid']
      instance.bid = job_hash['bid'] if instance.respond_to?(:bid=)
      instance._context = self
      instance
    end

    def execute_job(instance, job_hash, queue)
      @capsule.server_middleware.invoke(instance, job_hash, queue) do
        instance.perform(*job_hash['args'])
      end
    end

    # Bookkeeping wrapper. Publishes the in-flight job to WORK_STATE so the
    # Heartbeat can mirror it into Redis (`<identity>:work`), and increments
    # PROCESSED/FAILURE counters around the inner block.
    def stats(jobstr, queue)
      run_at = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :second)
      WORK_STATE.track(tid, queue: queue, payload: jobstr, run_at: run_at) do
        yield
      rescue Exception # rubocop:disable Lint/RescueException
        FAILURE.incr
        raise
      ensure
        PROCESSED.incr
      end
    end
  end
end
