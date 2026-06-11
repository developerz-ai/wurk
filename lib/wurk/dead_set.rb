# frozen_string_literal: true

require_relative 'job_set'

module Wurk
  # Capped ZSET of jobs that exhausted retries (the "morgue"). Bounded by
  # `dead_max_jobs` and `dead_timeout_in_seconds` config knobs — every
  # `kill` trims both axes. Death handlers fire by default — including on
  # API/UI kills, matching Sidekiq — unless `notify_failure: false`.
  #
  # Spec: docs/target/sidekiq-free.md §19.5, §17.2, §31.8.
  class DeadSet < JobSet
    # Synthesized as the death-handler exception for kills without a real
    # error. Byte-for-byte Sidekiq's message — Wurk::Unique::DEATH_HANDLER
    # matches on it to keep the lock on manual kills (Ent parity), and
    # ecosystem handlers may pattern-match it too.
    API_KILL_MESSAGE = 'Job killed by API'
    # Optional `name` allows tests to operate on a namespaced ZSET; production
    # callers always use the default `'dead'` key (wire-compat with Sidekiq).
    def initialize(name = 'dead')
      super
    end

    # Two-axis trim: `ZREMRANGEBYSCORE` evicts entries older than
    # `dead_timeout_in_seconds`, `ZREMRANGEBYRANK 0 -dead_max_jobs` keeps
    # the count bounded. Pipelined — partial failure leaves at most one
    # axis applied (acceptable; trim is non-critical, runs again next kill).
    #
    # `max_jobs:` / `timeout:` override the global config for this call.
    # Lets parallel tests run trim with isolated limits without mutating
    # `Wurk.configuration` (which is process-global and races across threads).
    def trim(max_jobs: nil, timeout: nil) # rubocop:disable Naming/PredicateMethod
      config = Wurk.configuration
      max_jobs ||= config[:dead_max_jobs] || 10_000
      timeout ||= config[:dead_timeout_in_seconds] || (180 * 24 * 60 * 60)
      cutoff = ::Process.clock_gettime(::Process::CLOCK_REALTIME) - timeout

      Wurk.redis do |conn|
        conn.pipelined do |pipe|
          pipe.call('ZREMRANGEBYSCORE', @name, '-inf', "(#{cutoff}")
          pipe.call('ZREMRANGEBYRANK', @name, 0, -(max_jobs + 1))
        end
      end
      true
    end

    # ZADD the raw JSON payload, trim, fire death handlers. `notify_failure:
    # true` (default) routes the kill through the death-handler chain;
    # UI-initiated kills pass false. `ex` is the originating exception (or
    # synthesized RuntimeError when callers don't have one) — death handlers
    # receive `(job, ex)`. `max_jobs:` / `timeout:` propagate to the auto-trim;
    # see `#trim` for the rationale.
    def kill(message, opts = {}) # rubocop:disable Naming/PredicateMethod
      notify = opts.fetch(:notify_failure, true)
      do_trim = opts.fetch(:trim, true)
      ex = opts[:ex] || RuntimeError.new(API_KILL_MESSAGE).tap { |e| e.set_backtrace(caller) }

      now = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
      Wurk.redis { |conn| conn.call('ZADD', @name, now.to_s, message) }
      trim(max_jobs: opts[:max_jobs], timeout: opts[:timeout]) if do_trim
      fire_death_handlers(message, ex) if notify
      true
    end

    private

    def fire_death_handlers(message, ex)
      job = parse_message(message)
      handlers = Wurk.configuration.death_handlers
      handlers.each do |handler|
        handler.call(job, ex)
      rescue StandardError => e
        Wurk.configuration.handle_exception(e, context: 'death handler')
      end
    end

    def parse_message(message)
      message.is_a?(String) ? Wurk.load_json(message) : message
    rescue ::JSON::ParserError
      { 'class' => 'Unknown', 'args' => [], '_raw' => message }
    end
  end
end
