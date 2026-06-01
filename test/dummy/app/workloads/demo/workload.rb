# frozen_string_literal: true

module Demo
  # Generates realistic, self-healing demo traffic so every dashboard widget
  # shows non-trivial values within ~30s of a cold start (issue #33).
  #
  # It's a feedback controller, not a fire-hose: each `tick!` tops the primary
  # queue back up to a target backlog (so throughput stays steady as the worker
  # drains it) and keeps the scheduled/retry/dead/batch/limiter/cron surfaces in
  # a band. `ensure_seeded!` runs every tick, so a Redis flush or app restart
  # self-heals within one interval — cron loops and limiters are re-registered
  # and the queues refill on their own.
  #
  # Run it as its own process (fork-safe — no swarm here):
  #   cd test/dummy && WURK_DEMO=1 bin/rails demo:workload
  # The worker process drains what this enqueues.
  class Workload
    PRIMARY_QUEUE    = 'default'
    SECONDARY_QUEUES = %w[high low].freeze
    TARGET_BACKLOG   = 60   # primary-queue depth the controller maintains
    SECONDARY_DEPTH  = 6    # keep high/low shallow but non-empty for the widget
    SCHEDULED_TARGET = 20
    RETRY_TARGET     = 12
    DEAD_TARGET      = 25
    BATCH_INTERVAL   = 12.0 # seconds between new demo batches
    MAX_PER_TICK     = 200  # cap a single top-up so a flush doesn't spike

    class << self
      # Building a limiter registers it into `lmtr-list` (register: true by
      # default), which is what makes it show up in the Limiters widget. The
      # accessors memoize a handle for repeated use (e.g. Demo::RateLimitedJob
      # in the worker); `build_*` constructs a fresh one so `ensure_seeded!` can
      # re-register after a Redis flush. All handles point at the same
      # Redis-backed limiter, keyed by name.
      def email_limiter = @email_limiter ||= build_email_limiter
      def api_limiter   = @api_limiter ||= build_api_limiter

      def build_email_limiter = Wurk::Limiter.bucket('demo-emails', 60, :minute, wait_timeout: 0)
      def build_api_limiter   = Wurk::Limiter.concurrent('demo-api', 5)
    end

    def initialize(logger: nil, interval: 1.0)
      @logger = logger
      @interval = interval
      @stop = false
      @last_batch_at = 0.0
    end

    def run
      install_signal_traps
      log "starting — backlog target #{TARGET_BACKLOG} on #{PRIMARY_QUEUE}, " \
          "#{SECONDARY_QUEUES.join('/')} kept shallow"
      until @stop
        begin
          tick!
        rescue StandardError => e
          log "tick error (continuing): #{e.class}: #{e.message}"
        end
        sleep @interval unless @stop
      end
      log 'stopped'
    end

    def stop
      @stop = true
    end

    # One control step. Public and side-effect-explicit so a test can run it
    # once and assert on the dashboard data it produced.
    def tick!
      ensure_seeded!
      top_up_primary
      top_up_secondary
      top_up_scheduled
      top_up_retries
      top_up_dead
      enqueue_rate_limited
      roll_batch
    end

    # Idempotent (re)registration of cron loops + limiters. Cheap, run every
    # tick, so the demo recovers within one interval of a Redis flush.
    def ensure_seeded!
      Wurk::Cron.register('demo report (minutely)', '* * * * *', 'Demo::ReportJob', [], queue: 'low')
      Wurk::Cron.register('demo sweep (hourly)', '0 * * * *', 'Demo::ReportJob', [], queue: 'default')
      self.class.build_email_limiter
      self.class.build_api_limiter
    end

    private

    def top_up_primary
      deficit = TARGET_BACKLOG - Wurk::Queue.new(PRIMARY_QUEUE).size
      return if deficit <= 0

      enqueue_fast(PRIMARY_QUEUE, [deficit, MAX_PER_TICK].min)
    end

    def top_up_secondary
      SECONDARY_QUEUES.each do |queue|
        deficit = SECONDARY_DEPTH - Wurk::Queue.new(queue).size
        enqueue_fast(queue, deficit) if deficit.positive?
      end
    end

    def top_up_scheduled
      deficit = SCHEDULED_TARGET - Wurk::ScheduledSet.new.size
      return if deficit <= 0

      [deficit, 5].min.times { Demo::FastJob.perform_in(rand(30..600)) }
    end

    def top_up_retries
      return if Wurk::RetrySet.new.size >= RETRY_TARGET

      3.times { Demo::FlakyJob.perform_async }
    end

    def top_up_dead
      return if Wurk::DeadSet.new.size >= DEAD_TARGET

      Demo::PoisonJob.perform_async
    end

    def enqueue_rate_limited
      Demo::RateLimitedJob.perform_async
    end

    def roll_batch
      now = monotonic
      return if now - @last_batch_at < BATCH_INTERVAL

      @last_batch_at = now
      batch = Wurk::Batch.new
      batch.description = "Demo export #{Time.now.strftime('%H:%M:%S')}"
      batch.on(:success, 'Demo::BatchCallback')
      batch.on(:complete, 'Demo::BatchCallback')
      batch.jobs { rand(5..12).times { Demo::BatchChildJob.perform_async } }
    end

    def enqueue_fast(queue, count)
      Demo::FastJob.set(queue: queue).perform_bulk(Array.new(count) { [] })
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def install_signal_traps
      %w[INT TERM].each { |sig| trap(sig) { stop } }
    end

    def log(message)
      @logger&.info("[demo] #{message}")
    end
  end
end
