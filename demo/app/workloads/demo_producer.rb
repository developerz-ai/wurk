# frozen_string_literal: true

# Generates light, self-healing demo traffic so every dashboard surface shows
# live data — and never looks dead — without taxing the public demo server.
#
# It's a feedback controller: each tick tops shallow target bands back up as the
# worker drains, and keeps the scheduled / retry / dead / batch / limiter / cron
# surfaces populated. `ensure_seeded!` runs every tick, so a Redis flush or
# restart self-heals within one interval.
#
# Tuned for a public demo: a ~10s tick with shallow targets means only a trickle
# of jobs (≈1–2 / 10s in steady state), enough to keep every widget live. Tune
# the cadence at runtime with DEMO_PRODUCER_INTERVAL (seconds) — no rebuild.
#
# Run as its own process:  cd demo && WURK_DEMO=1 bin/rails demo:workload
class DemoProducer
  PRIMARY_QUEUE    = "default"
  SECONDARY_QUEUES = %w[high low].freeze
  DEFAULT_INTERVAL = 10.0
  TARGET_BACKLOG   = 2     # primary-queue depth — a trickle, ~1 job per tick
  SECONDARY_DEPTH  = 1
  SCHEDULED_TARGET = 5     # these sit in their sets (no ongoing processing) — kept for showcase
  RETRY_TARGET     = 4
  DEAD_TARGET      = 5
  PROFILE_TARGET   = 6     # stored vernier captures (7-day TTL) — enough rows, bounded Redis
  BATCH_INTERVAL   = 120.0
  MAX_PER_TICK     = 1     # never enqueue more than one primary job per tick
  EXTRAS_EVERY     = 3     # fire the unique-job + limiter samples only every Nth tick

  class << self
    def api_limiter = @api_limiter ||= build_api_limiter
    def build_api_limiter = Wurk::Limiter.bucket("demo-api", 60, :minute, wait_timeout: 0)
  end

  def initialize(logger: nil, interval: nil)
    @logger = logger
    @interval = interval || (ENV["DEMO_PRODUCER_INTERVAL"]&.to_f&.nonzero?) || DEFAULT_INTERVAL
    @stop = false
    @last_batch_at = nil # nil → first tick always rolls a batch; BATCH_INTERVAL spaces the rest
    @tick = 0
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
    @tick += 1
    ensure_seeded!
    top_up_primary
    top_up_secondary
    top_up_scheduled
    top_up_retries
    top_up_dead
    top_up_profiles
    # Keep the unique-jobs + limiter surfaces alive, but only occasionally so the
    # steady-state load stays at roughly one job per tick.
    if (@tick % EXTRAS_EVERY).zero?
      SendReceiptJob.perform_async(rand(1..500)) # unique — dups within 30s drop
      ThrottledApiJob.perform_async
    end
    roll_export_batch
  end

  # Idempotent (re)registration of the cron schedule + limiter. Cheap; runs
  # every tick so the demo recovers within one interval of a Redis flush.
  def ensure_seeded!
    # A few loops at different cadences so the Cron tab shows a realistic mix of
    # "last fired" / "next run" rather than a single row. The every-minute and
    # 5-minute loops fire during a browse; the nightly one shows a future next-run.
    Wurk::Cron.register("demo daily report",   "* * * * *",   "DailyReportJob",   [], queue: "low")
    Wurk::Cron.register("demo cache warmup",   "*/5 * * * *", "ThrottledApiJob",  [], queue: "high")
    # Cron → batch: the fired job OPENS the export batch, so a browser can
    # follow one storyline across Cron → Batches → Queues/Busy → Retries.
    Wurk::Cron.register("demo nightly export", "0 0 * * *",   "NightlyExportJob", [], queue: "default")
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

  # Keeps the Profiles page populated with real vernier flame-graph captures.
  # `profile:` rides the job hash (Sidekiq 8.0 OSS parity); the processor wraps
  # perform in a Vernier capture and stores the gzipped gecko JSON for 7 days.
  def top_up_profiles
    return if Wurk::ProfileSet.new.size >= PROFILE_TARGET

    WelcomeJob.set(profile: "demo-welcome").perform_async(rand(1..999))
  end

  # Between cron's midnight firings, keep the Batches page live by enqueuing
  # the same NightlyExportJob cron runs — batch creation always happens inside
  # a worker, exactly like production code would do it.
  def roll_export_batch
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return if @last_batch_at && now - @last_batch_at < BATCH_INTERVAL

    @last_batch_at = now
    NightlyExportJob.perform_async
  end

  def log(message)
    @logger&.info("[demo] #{message}")
  end
end
