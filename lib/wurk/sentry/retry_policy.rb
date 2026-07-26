# frozen_string_literal: true

require_relative '../job_retry'

module Wurk
  module Sentry
    # Answers one question: "if this job raises right now, is that the end of
    # the road?" Only terminal failures are worth an alert — reporting every
    # attempt turns a single flaky job into 25 Sentry events over ~21 days.
    #
    # The prediction has to be made *ahead* of {Wurk::JobRetry}, because the
    # server middleware chain runs inside `JobRetry#local` (see
    # `Processor#dispatch`): the middleware's rescue fires before the retry
    # layer has touched the payload. So at rescue time `retry_count` is still
    # the number of retries already *performed*, and this class re-derives
    # what `JobRetry#process_retry` is about to conclude:
    #
    #   * `bump_retry_count` sets `retry_count = 0` on the first failure and
    #     `retry_count += 1` thereafter — so the post-bump count is
    #     `retry_count.nil? ? 0 : retry_count + 1`.
    #   * `exhausted?` kills the job once that count reaches `max_attempts`.
    #
    # Which makes the last attempt the one that arrives with
    # `retry_count == max_attempts - 1` (and, for `retry: 0` / `retry: false`,
    # the very first one).
    #
    # Not predictable from the payload — and therefore reported one attempt
    # late, or not at all: a `sidekiq_retry_in` block returning `:discard` or
    # `:kill`. Those are host decisions made after this point.
    module RetryPolicy
      module_function

      def terminal?(job, instance = nil, config = nil)
        retry_option = retry_option_for(job, instance)
        return true unless retry_option
        # `retry_for` is a wall-clock budget that supersedes the attempt count
        # entirely (JobRetry#exhausted? branches on it before looking at max).
        return retry_for_elapsed?(job) if job['retry_for']

        next_retry_count(job) >= max_attempts(retry_option, config)
      end

      # Mirrors `JobRetry#local`: a payload with no `retry` key falls back to
      # the worker class's own `sidekiq_options`.
      def retry_option_for(job, instance)
        value = job['retry']
        return value unless value.nil?

        klass = instance&.class
        klass.respond_to?(:get_sidekiq_options) ? klass.get_sidekiq_options['retry'] : true
      end

      def next_retry_count(job)
        count = job['retry_count']
        count ? count + 1 : 0
      end

      def max_attempts(retry_option, config)
        return retry_option if retry_option.is_a?(::Integer)

        configured_max_retries(config) || Wurk::JobRetry::DEFAULT_MAX_RETRY_ATTEMPTS
      end

      # `config` is whatever the Chain bound to the middleware — a Capsule in a
      # running worker, a Configuration in tests. Only the latter has `[]`.
      def configured_max_retries(config)
        return nil if config.nil?

        inner = config.respond_to?(:config) ? config.config : config
        inner.respond_to?(:[]) ? inner[:max_retries] : nil
      end

      def retry_for_elapsed?(job)
        failed_at = job['failed_at']
        # First failure: JobRetry stamps `failed_at = now` and then finds the
        # budget un-spent, so the job always gets at least one retry.
        return false unless failed_at

        time_for(failed_at) + job['retry_for'] < ::Time.now
      end

      # Wire format matches JobRetry#time_for: Float seconds or Integer millis.
      def time_for(value)
        return ::Time.at(value) if value.is_a?(::Float)

        ::Time.at(value / 1000, value % 1000, :millisecond)
      end
    end
  end
end
