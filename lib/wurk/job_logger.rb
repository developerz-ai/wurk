# frozen_string_literal: true

module Wurk
  # Wraps the per-job execution span. Logs "start"/"done"/"fail" at INFO,
  # pushes :elapsed into Wurk::Context so the logger formatter can pick it
  # up, and prepares the thread-local context hash (jid, class, plus
  # config[:logged_job_attributes]).
  #
  # Two entry points, called from Processor#process in this order:
  #   1. prepare(job_hash) { ... }  → sets thread-local context, applies
  #      per-job log_level, yields to the rest of dispatch.
  #   2. call(item, queue) { ... }  → wraps the actual perform with the
  #      start/done/fail log line trio and the elapsed-ms measurement.
  #
  # Skipping default logging is controlled by config[:skip_default_job_logging];
  # the prepare step still runs so context/log_level still apply.
  #
  # Spec: docs/target/sidekiq-free.md §18.
  class JobLogger
    def initialize(config)
      @config = config
      @logger = @config.logger
      @skip = !!@config[:skip_default_job_logging]
    end

    def call(_item, _queue)
      start = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      @logger.info { 'start' } unless @skip

      yield

      Wurk::Context.add(:elapsed, elapsed(start))
      @logger.info { 'done' } unless @skip
    rescue Exception # rubocop:disable Lint/RescueException
      Wurk::Context.add(:elapsed, elapsed(start))
      @logger.info { 'fail' } unless @skip
      raise
    end

    # Sets thread-local context for the duration of `block`, optionally
    # under a per-job log level. ActiveJob-wrapped jobs expose the real
    # class via the "wrapped" key — log that, not the wrapper.
    def prepare(job_hash, &block)
      h = context_hash(job_hash)

      level = job_hash['log_level']
      Wurk::Context.with(h) do
        if level
          @logger.with_level(level, &block)
        else
          yield
        end
      end
    end

    private

    def elapsed(start)
      (::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - start).round(3)
    end

    def context_hash(job_hash)
      h = {
        jid: job_hash['jid'],
        class: job_hash['wrapped'] || job_hash['class']
      }

      # logged_job_attributes defaults to %w[bid tags]; most jobs carry
      # neither, so skip the walk entirely unless one is present.
      return h unless job_hash.key?('bid') || job_hash.key?('tags')

      @config[:logged_job_attributes].each do |attr|
        h[attr.to_sym] = job_hash[attr] if job_hash.key?(attr)
      end
      h
    end
  end
end
