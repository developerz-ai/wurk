# frozen_string_literal: true

require 'zlib'
require_relative 'component'
require_relative 'dead_set'

module Wurk
  # Owns the retry pipeline. When perform raises, JobRetry decides whether to
  # reschedule (`retry` ZSET, exponential backoff + jitter), drop, kill, or
  # send to the morgue. Wire-compat sacred: error_message / error_class /
  # retry_count / failed_at / retried_at / error_backtrace field names and
  # encodings (base64 of zlib of JSON for the backtrace) match Sidekiq byte
  # for byte — third-party gems and the dashboard read them directly.
  #
  # Two entry points wrap the dispatch onion in Processor#dispatch:
  #
  #   * `global(jobstr, queue)` — outermost, no job instance required.
  #     Rescues `Exception` so pre-instantiation failures (const_get, reloader)
  #     still get a retry recorded. Re-raises `Handled` so the processor
  #     skips ACK logging.
  #   * `local(jobinst, jobstr, queue)` — inner, runs after the worker is
  #     instantiated. Honors per-class `sidekiq_retry_in_block` /
  #     `sidekiq_retries_exhausted_block` (and the wrapped-class variants).
  #     Raises `Handled` after booking the retry so `global` does not double-
  #     process the failure.
  #
  # Spec: docs/target/sidekiq-free.md §17.
  class JobRetry # rubocop:disable Metrics/ClassLength
    include Component

    DEFAULT_MAX_RETRY_ATTEMPTS = 25

    # Raised after process_retry has dealt with the failure. The processor
    # rescues `Handled` and exits the job cleanly (acked, no re-raise).
    class Handled < ::RuntimeError; end

    # Subclass of Handled with the same semantics — used when middleware
    # short-circuits processing (e.g. interrupt-handler re-pushed the job).
    class Skip < Handled; end

    def initialize(capsule)
      @capsule = capsule
      @config = capsule
      @max_retries = inner_config_get(:max_retries) || DEFAULT_MAX_RETRY_ATTEMPTS
      @backtrace_cleaner = inner_config_get(:backtrace_cleaner)
    end

    # Outermost retry guard. Rescues `Exception` so const_get / reloader
    # failures still get a retry. `Handled` is re-raised intact; `Shutdown`
    # bubbles up so the swarm can drain.
    def global(jobstr, queue)
      yield
    rescue Handled, Wurk::Shutdown
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      raise Wurk::Shutdown if exception_caused_by_shutdown?(e)

      msg = Wurk.load_json(jobstr)
      if msg['retry']
        process_retry(nil, msg, queue, e)
      else
        run_death_handlers(msg, e)
      end

      raise Handled
    end

    # Per-job retry guard. Same rescue semantics as `global` but the worker
    # instance is in hand, so per-class `sidekiq_retry_in_block` and
    # `sidekiq_retries_exhausted_block` can run. Raises `Handled` to short-
    # circuit `global`'s rescue.
    def local(jobinst, jobstr, queue)
      yield
    rescue Handled, Wurk::Shutdown
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      raise Wurk::Shutdown if exception_caused_by_shutdown?(e)

      msg = Wurk.load_json(jobstr)
      msg['retry'] = jobinst.class.get_sidekiq_options['retry'] if msg['retry'].nil?

      raise e unless msg['retry']

      process_retry(jobinst, msg, queue, e)
      raise Handled
    end

    # Component's `handle_exception` delegates to `config.handle_exception`.
    # When initialized with a Capsule, that's not defined directly; route
    # through the underlying Configuration.
    def handle_exception(ex, ctx = {})
      inner_config.handle_exception(ex, ctx)
    end

    private

    def now_ms
      ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
    end

    # Bumps retry counters, stamps the error payload, decides next action:
    #   * `retry_for` exceeded → retries_exhausted
    #   * count >= attempts    → retries_exhausted
    #   * sidekiq_retry_in returned :discard → drop + death_handlers
    #   * sidekiq_retry_in returned :kill    → retries_exhausted (morgue)
    #   * otherwise → ZADD into `retry` at now + delay + jitter
    def process_retry(jobinst, msg, queue, exception)
      max_attempts = retry_attempts_from(msg['retry'], @max_retries)

      msg['queue'] = msg['retry_queue'] || queue

      stamp_error(msg, exception)
      count = bump_retry_count(msg)
      stamp_backtrace(msg, exception)

      return if exhausted?(jobinst, msg, count, max_attempts, exception)

      strategy, delay = delay_for(jobinst, count, exception, msg)
      case strategy
      when :discard
        msg['discarded_at'] = now_ms
        return run_death_handlers(msg, exception)
      when :kill
        return retries_exhausted(jobinst, msg, exception)
      end

      schedule_retry(msg, count, delay)
    end

    def exhausted?(jobinst, msg, count, max_attempts, exception)
      rf = msg['retry_for']
      if rf
        return false unless retry_for_exceeded?(msg['failed_at'], rf)
      elsif count < max_attempts
        return false
      end
      retries_exhausted(jobinst, msg, exception)
      true
    end

    def stamp_error(msg, exception)
      m = exception_message(exception)
      if m.respond_to?(:scrub!)
        m.force_encoding(::Encoding::UTF_8)
        m.scrub!
      end
      msg['error_message'] = m
      msg['error_class'] = exception.class.name
    end

    # Returns the resulting count. First failure: `retry_count=0`, `failed_at`
    # set; subsequent failures bump `retry_count` and set `retried_at`.
    def bump_retry_count(msg)
      if msg['retry_count']
        msg['retried_at'] = now_ms
        msg['retry_count'] += 1
      else
        msg['failed_at'] = now_ms
        msg['retry_count'] = 0
      end
    end

    # `backtrace: true` → keep all; `backtrace: N` → keep first N.
    # Stored as base64(zlib(JSON(lines))) — wire-compat with Sidekiq, keeps
    # Redis payload size bounded for jobs with deep stacks.
    def stamp_backtrace(msg, exception)
      return unless msg['backtrace']
      return if exception.backtrace.nil?

      cleaned = (@backtrace_cleaner || ->(bt) { bt }).call(exception.backtrace)
      lines = msg['backtrace'] == true ? cleaned : cleaned[0...msg['backtrace'].to_i]
      msg['error_backtrace'] = compress_backtrace(lines)
    end

    def retry_for_exceeded?(failed_at, retry_for)
      return false unless failed_at

      time_for(failed_at) + retry_for < ::Time.now
    end

    def schedule_retry(msg, count, delay)
      jitter = rand(10 * (count + 1))
      retry_at = ::Time.now.to_f + delay + jitter
      payload = Wurk.dump_json(msg)
      redis do |conn|
        conn.call('ZADD', Keys::RETRY, retry_at.to_s, payload)
      end
      Wurk::Metrics::Statsd.increment(
        'jobs.retried',
        tags: ["worker:#{msg['class']}", "queue:#{msg['queue']}"]
      )
    end

    def time_for(item)
      if item.is_a?(::Float)
        ::Time.at(item)
      else
        ::Time.at(item / 1000, item % 1000)
      end
    end

    # Returns `[strategy, seconds]`. Strategy ∈ {:default, :discard, :kill}.
    # Caller branches on strategy; seconds is meaningful only for :default.
    def delay_for(jobinst, count, exception, msg)
      rv = run_retry_in_block(jobinst, count, exception, msg)
      rv = rv.to_i if rv.is_a?(::Float)
      default_delay = (count**4) + 15

      case rv
      when ::Integer
        return [:default, rv] if rv.positive?
      when :discard
        return [:discard, nil]
      when :kill
        return [:kill, nil]
      end

      [:default, default_delay]
    end

    def run_retry_in_block(jobinst, count, exception, msg) # rubocop:disable Metrics/CyclomaticComplexity
      block = jobinst&.class&.sidekiq_retry_in_block
      block = wrapped_block(msg, :sidekiq_retry_in_block) || block if msg['wrapped']
      block&.call(count, exception, msg)
    rescue ::Exception => e # rubocop:disable Lint/RescueException
      handle_exception(e, context: "Failure scheduling retry via `sidekiq_retry_in` on #{jobinst&.class&.name}")
      nil
    end

    # Runs `sidekiq_retries_exhausted` (or the wrapped-class variant). Then
    # `:discard` / `msg["dead"] == false` skips the morgue; otherwise the
    # raw JSON is ZADD'd into `dead` and trimmed. Death handlers always fire.
    def retries_exhausted(jobinst, msg, exception)
      rv = run_exhausted_block(jobinst, msg, exception)
      discarded = msg['dead'] == false || rv == :discard

      if discarded
        msg['discarded_at'] = now_ms
      else
        send_to_morgue(msg)
      end

      run_death_handlers(msg, exception)
    end

    def run_exhausted_block(jobinst, msg, exception)
      block = jobinst&.class&.sidekiq_retries_exhausted_block
      block = wrapped_block(msg, :sidekiq_retries_exhausted_block) || block if msg['wrapped']
      block&.call(msg, exception)
    rescue ::Exception => e # rubocop:disable Lint/RescueException
      handle_exception(e, context: 'Error calling retries_exhausted', job: msg)
      nil
    end

    # Wrappers (ActiveJob, custom) expose retry blocks on the wrapped class
    # via `msg["wrapped"]`. We look up the constant and prefer its block.
    def wrapped_block(msg, attr)
      wrapped = ::Object.const_get(msg['wrapped'])
      wrapped.respond_to?(attr) ? wrapped.public_send(attr) : nil
    rescue ::NameError
      nil
    end

    def send_to_morgue(msg)
      logger.info { "Adding dead #{msg['class']} job #{msg['jid']}" }
      DeadSet.new.kill_raw(Wurk.dump_json(msg))
    end

    def run_death_handlers(job, exception)
      inner_config.death_handlers.each do |handler|
        handler.call(job, exception)
      rescue ::StandardError => e
        handle_exception(e, context: 'Error calling death handler', job: job)
      end
    end

    def retry_attempts_from(msg_retry, default)
      msg_retry.is_a?(::Integer) ? msg_retry : default
    end

    # Walks `e.cause` chain looking for a `Wurk::Shutdown`. Prevents user
    # `rescue => e` blocks (that should have re-raised Shutdown) from being
    # treated as a normal failure that triggers retry recording.
    def exception_caused_by_shutdown?(exception, checked = [])
      return false unless exception.cause

      checked << exception.object_id
      return false if checked.include?(exception.cause.object_id)

      exception.cause.instance_of?(Wurk::Shutdown) ||
        exception_caused_by_shutdown?(exception.cause, checked)
    end

    def exception_message(exception)
      exception.message.to_s[0, 10_000]
    rescue ::StandardError
      +'!!! ERROR MESSAGE THREW AN ERROR !!!'
    end

    def compress_backtrace(backtrace)
      serialized = Wurk.dump_json(backtrace)
      compressed = ::Zlib::Deflate.deflate(serialized)
      [compressed].pack('m0')
    end

    # Returns the Configuration even when @capsule is a Capsule. Capsule
    # exposes config via `#config`; if a bare Configuration was passed
    # (tests, embedded mode), it's already the config.
    def inner_config
      @capsule.respond_to?(:config) ? @capsule.config : @capsule
    end

    def inner_config_get(key)
      cfg = inner_config
      cfg.respond_to?(:[]) ? cfg[key] : nil
    end
  end
end
