# frozen_string_literal: true

# Generates continuous, self-healing demo traffic so every dashboard surface
# shows live data within ~30s of a cold start — and never looks dead.
#
# It's a feedback controller: each tick tops the primary queue back up to a
# target backlog (steady throughput as the worker drains) and keeps the
# scheduled / retry / dead / batch / limiter / cron surfaces in a band.
# `ensure_seeded!` runs every tick, so a Redis flush or restart self-heals
# within one interval.
#
# Run as its own process:  cd demo && WURK_DEMO=1 bin/rails demo:workload
class DemoProducer
  PRIMARY_QUEUE    = "default"
  SECONDARY_QUEUES = %w[high low].freeze
  TARGET_BACKLOG   = 60
  SECONDARY_DEPTH  = 6
  SCHEDULED_TARGET = 20
  RETRY_TARGET     = 12
  DEAD_TARGET      = 25
  BATCH_INTERVAL   = 12.0
  MAX_PER_TICK     = 200

  class << self
    def api_limiter = @api_limiter ||= build_api_limiter
    def build_api_limiter = Wurk::Limiter.bucket("demo-api", 60, :minute, wait_timeout: 0)
  end

  def initialize(logger: nil, interval: 1.0)
    @logger = logger
    @interval = interval
    @stop = false
    @last_batch_at = 0.0
  end

  def run
    %w[INT TERM].each { |sig| trap(sig) { @stop = true } }
    log "demo producer starting"
    until @stop
      begin
        tick!
      rescue StandardError => e
        log "tick error (continuing): #{e.class}: #{e.message}"
      end
      sleep @interval unless @stop
    end
    log "demo producer stopped"
  end

  # One control step — public so a rake task / test can run it once.
  def tick!
    ensure_seeded!
    top_up_primary
    top_up_secondary
    top_up_scheduled
    top_up_retries
    top_up_dead
    SendReceiptJob.perform_async(rand(1..500)) # unique — dups within 30s drop
    ThrottledApiJob.perform_async
    roll_export_batch
  end

  # Idempotent (re)registration of the cron schedule + limiter. Cheap; runs
  # every tick so the demo recovers within one interval of a Redis flush.
  def ensure_seeded!
    Wurk::Cron.register("demo daily report", "* * * * *", "DailyReportJob", [], queue: "low")
    self.class.build_api_limiter
  end

  private

  def top_up_primary
    deficit = TARGET_BACKLOG - Wurk::Queue.new(PRIMARY_QUEUE).size
    return if deficit <= 0

    WelcomeJob.set(queue: PRIMARY_QUEUE).perform_bulk([deficit, MAX_PER_TICK].min.times.map { |i| [i] })
  end

  def top_up_secondary
    SECONDARY_QUEUES.each do |queue|
      deficit = SECONDARY_DEPTH - Wurk::Queue.new(queue).size
      WelcomeJob.set(queue: queue).perform_bulk(deficit.times.map { |i| [i] }) if deficit.positive?
    end
  end

  def top_up_scheduled
    deficit = SCHEDULED_TARGET - Wurk::ScheduledSet.new.size
    [deficit, 5].min.times { WelcomeJob.perform_in(rand(30..600), rand(1..999)) } if deficit.positive?
  end

  def top_up_retries
    3.times { FlakyWebhookJob.perform_async } if Wurk::RetrySet.new.size < RETRY_TARGET
  end

  def top_up_dead
    BrokenJob.perform_async if Wurk::DeadSet.new.size < DEAD_TARGET
  end

  def roll_export_batch
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if now - @last_batch_at < BATCH_INTERVAL

    @last_batch_at = now
    batch = Wurk::Batch.new
    batch.description = "Nightly export #{Time.now.strftime('%H:%M:%S')}"
    batch.on(:success, "ExportCallback")
    batch.on(:complete, "ExportCallback")
    batch.jobs { rand(5..12).times { |i| ExportChunkJob.perform_async(i) } }
  end

  def log(message)
    @logger&.info("[demo] #{message}")
  end
end
