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
      begin
        process_one until @done
      ensure
        flush_acks
      end
      @callback&.call(self)
    rescue Wurk::Shutdown
      @callback&.call(self)
    rescue Exception => e # rubocop:disable Lint/RescueException
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

    def process(uow)
      jobstr = uow.job
      queue  = uow.queue_name

      job_hash = parse_or_kill(jobstr, uow)
      return if job_hash.nil?

      # The fetcher never parses, so hand it the jid we just read: the ACK
      # retires this job's poison-pill recovery counter inside the round trip
      # it rides. A fetcher plugged in via `config[:fetch_class]` has no jid
      # slot and simply ACKs — the counter then ages out on its 72h TTL.
      uow.jid = job_hash['jid'] if uow.respond_to?(:jid=)

      ack = false
      begin
        Thread.handle_interrupt(IGNORE_SHUTDOWN_INTERRUPTS) do
          dispatch(job_hash, queue, jobstr) do |instance|
            Thread.handle_interrupt(ALLOW_SHUTDOWN_INTERRUPTS) do
              execute_job(instance, job_hash, queue)
            end
          end
          ack = true
        end
      rescue Wurk::JobRetry::Handled
        # Handled / JobRetry::Skip (incl. Limiter::Rescheduled, where the
        # limiter middleware already re-enqueued the job) — the retry layer or
        # a middleware booked the outcome and recorded no retry; ack the UoW.
        ack = true
      rescue Wurk::Shutdown
        # Don't ack — UoW stays in private list and is reclaimed on reboot.
      ensure
        # This frame is the one every exit path passes through, which is why a
        # global-concurrency slot is given back from here and nowhere else: a
        # clean return, a failure, a retry, `Handled`, the watchdog's async
        # raise for a timeout or a deadline, the shutdown raise. A release added
        # to any single arm above is a release the next arm forgets, and a
        # forgotten one strands cluster-wide capacity for the whole slot TTL.
        #
        # One call on either branch, never a release on its own line after the
        # ACK: an async raise can land inside this frame (SharedWorkState#track
        # has the same hazard), and a second statement here is one that
        # sometimes does not run. So the ACK carries the slot's ZREM in its own
        # pipeline, and only the path that deliberately does not ACK — the
        # shutdown, whose payload goes back to the queue for someone else to run
        # — releases by itself.
        if ack
          uow.acknowledge
        elsif uow.respond_to?(:release_slot)
          release_slot(uow)
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
    # morgue exactly like send_to_morgue does — spec §31.8/§31.9) and ack.
    # Returns nil to signal "no further processing".
    def parse_or_kill(jobstr, uow)
      Wurk.load_json(jobstr)
    rescue ::JSON::ParserError => e
      handle_exception(e, { context: 'Invalid JSON', jobstr: jobstr })
      DeadSet.new.kill_raw(jobstr)
      uow.acknowledge
      nil
    end

    # Wraps the actual perform in the dispatch onion: logger.prepare →
    # retrier.global → logger.call → stats → reloader → instantiate
    # → retrier.local → (yield to caller for middleware + perform).
    def dispatch(job_hash, queue, jobstr)
      @job_logger.prepare(job_hash) do
        @retrier.global(jobstr, queue) do
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
