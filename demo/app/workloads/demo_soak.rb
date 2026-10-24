# frozen_string_literal: true

require "net/http"
require "json"
require "securerandom"

class DemoSoak
  INTERVAL = 60
  BACKLOG_LIMIT = 40
  BATCH_LIMIT = 10
  # Redis with maxmemory=0 is not permission to consume unbounded demo memory.
  ABSOLUTE_MEMORY_LIMIT = 128 * 1024 * 1024
  PATHS = %w[stats queues retries scheduled dead processes batches limiters cron].map { |p| "/wurk/api/#{p}" }.freeze

  def self.enabled?
    %w[WURK_DEMO WURK_DEMO_SOAK WURK_DEMO_PRODUCER WURK_DISABLED].all? { |key| ENV[key] == "1" }
  end

  def initialize(logger: nil, probe: nil)
    @pid = Process.pid
    @logger = logger
    @probe = probe || method(:dashboard_get)
  end

  def run
    while self.class.enabled? && Process.pid == @pid
      begin
        tick!
      rescue StandardError => e
        @logger&.warn("[demo-soak] cycle stopped: #{e.class}: #{e.message}")
      end
      sleep INTERVAL
    end
  end

  def tick!
    return false unless self.class.enabled? && Process.pid == @pid
    return false unless memory_safe? && backlog_safe?
    return false unless PATHS.all? { |path| @probe.call(path) }

    token = SecureRandom.hex(8)
    Wurk::Cron.register("demo soak", "* * * * *", "SoakJob::Cron", ["minute"],
      queue: "low", tags: [SoakJob::TAG], retry: 2, dead: false)
    SoakJob::RetryOnce.perform_async(token)
    SoakJob.perform_in(2, token)
    batch = Wurk::Batch.new
    batch.description = "demo-soak"
    batch.tags = [SoakJob::TAG]
    batch.expires_in(SoakJob::TTL)
    batch.linger = SoakJob::TTL
    %i[complete success].each { |event| batch.on(event, "SoakJob::Callback", "token" => token, "tags" => [SoakJob::TAG]) }
    batch.jobs { 2.times { |n| SoakJob::BatchMember.perform_async("#{token}:#{n}") } }
    Wurk.redis { |c| c.call("ZADD", "demo-soak:batches", Time.now.to_f, batch.bid) }
    2.times { SoakJob::Unique.perform_async("duplicate") }
    3.times { SoakJob::BucketLimited.perform_async(token) }
    restart_one_worker!
    true
  end

  def memory_safe?
    raw = Wurk.redis { |c| c.call("INFO", "memory") }
    info = raw.is_a?(Hash) ? raw : raw.lines.filter_map { |line| line.strip.split(":", 2) if line.include?(":") }.to_h
    used = Integer(info.fetch("used_memory"))
    maximum = Integer(info.fetch("maxmemory"))
    return false if used.negative? || maximum.negative?

    ceiling = maximum.zero? ? ABSOLUTE_MEMORY_LIMIT : [maximum * 4 / 5, ABSOLUTE_MEMORY_LIMIT].min
    used < ceiling
  rescue StandardError
    false
  end

  def backlog_safe?
    Wurk.redis do |c|
      depth = %w[high default low].sum { |q| c.call("LLEN", "queue:#{q}") }
      depth += %w[retry schedule].sum { |key| c.call("ZCARD", key) }
      # Bound our index entries too; expired batch hashes otherwise leave index members.
      bids = c.call("ZRANGE", "demo-soak:batches", 0, -1)
      bids.each do |bid|
        next unless c.call("EXISTS", "b-#{bid}").zero?

        c.call("ZREM", "batches", bid)
        c.call("ZREM", "demo-soak:batches", bid)
      end
      depth < BACKLOG_LIMIT && c.call("ZCARD", "demo-soak:batches") < BATCH_LIMIT
    end
  end

  def restart_one_worker!
    worker = Wurk::ProcessSet.new(false).find do |process|
      !process.embedded? && !process.stopping? && process.tag == "demo" &&
        process["beat"].to_f > Time.now.to_f - 30
    end
    worker&.stop!
  end

  private

  def dashboard_get(path)
    # Fixed loopback destination; never follow redirects or accept a supplied URL.
    Net::HTTP.start("127.0.0.1", Integer(ENV.fetch("PORT", "3000")),
      open_timeout: 1, read_timeout: 1, write_timeout: 1) do |http|
      response = http.request(Net::HTTP::Get.new(path, "Accept" => "application/json"))
      response.code == "200" && [Hash, Array].any? { |type| JSON.parse(response.body).is_a?(type) }
    end
  rescue StandardError
    false
  end
end
