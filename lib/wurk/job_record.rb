# frozen_string_literal: true

require 'base64'
require 'zlib'

module Wurk
  # One job payload viewed from the data API (Queue#each / JobSet#each).
  # Wraps the raw JSON string from Redis; parses lazily so an O(n) scan
  # over a large queue doesn't pay JSON cost for jobs that go unused.
  #
  # The `value` (raw JSON string) is what Redis stores; `LREM` matches
  # exact bytes, so `delete` must use it rather than re-serialize.
  #
  # Spec: docs/target/sidekiq-free.md §19.3.
  class JobRecord
    # Pre-compiled. ActiveJob's wrapper class varies per Rails minor
    # (`ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper`,
    # `ActiveJob::QueueAdapters::WurkAdapter::JobWrapper`, etc.).
    ACTIVE_JOB_WRAPPER = /\AActiveJob::QueueAdapters::.+::JobWrapper\z/
    ACTION_MAILER_JOBS = %w[
      ActionMailer::DeliveryJob
      ActionMailer::Parameterized::DeliveryJob
      ActionMailer::MailDeliveryJob
    ].freeze

    attr_reader :queue

    # @param item [String, Hash] raw JSON payload or pre-parsed hash.
    # @param queue_name [String, nil] queue this record came from.
    def initialize(item, queue_name = nil)
      if item.is_a?(String)
        @value = item
        @item = nil
      else
        @item = item
        @value = nil
      end
      @queue = queue_name || (@item && @item['queue'])
    end

    # Lazily parsed payload. Memoized; never re-parses.
    def item
      @item ||= Wurk.load_json(@value)
    end

    # Lazily serialized payload. When constructed from a Hash, we
    # generate JSON on first call so `delete` (LREM) has exact bytes.
    def value
      @value ||= Wurk.dump_json(@item)
    end

    def klass         = item['class']
    def args          = item['args']
    def jid           = item['jid']
    def bid           = item['bid']
    def tags          = item['tags'] || []
    def enqueued_at   = parse_time(item['enqueued_at'])
    def created_at    = parse_time(item['created_at'])
    def failed_at     = parse_time(item['failed_at'])
    def retried_at    = parse_time(item['retried_at'])

    # Hash-like reader for arbitrary payload fields. Spec §19.3.
    def [](name) = item[name]

    # Sidekiq compresses the bt as base64(zlib.deflate(JSON.dump(bt))).
    # Returns nil when no error has been recorded.
    def error_backtrace
      compressed = item['error_backtrace']
      return nil unless compressed

      Wurk.load_json(Zlib.inflate(Base64.decode64(compressed)))
    rescue Zlib::DataError, ArgumentError, ::JSON::ParserError
      nil
    end

    # Seconds since enqueued_at. Handles legacy float-seconds and
    # current integer-ms `enqueued_at` shapes. Returns 0.0 when missing
    # or somehow in the future (clock skew).
    def latency
      JobRecord.latency_from(item['enqueued_at'])
    end

    # Removes exactly this payload's bytes from the queue list. Returns
    # true when LREM removed ≥1 entry. Idempotent. Method name is
    # Sidekiq wire-compat — renaming would break `JobRecord#delete`.
    def delete # rubocop:disable Naming/PredicateMethod
      removed = Wurk.redis { |c| c.call('LREM', Keys.queue(@queue), 1, value) }
      removed.to_i.positive?
    end

    # ActiveJob/ActionMailer unwrappers — UI-facing only. For plain Wurk
    # workers, returns the raw class name.
    def display_class
      return @display_class if defined?(@display_class)

      @display_class = active_job_wrapper? ? unwrap_class : klass
    end

    def display_args
      return @display_args if defined?(@display_args)

      @display_args = active_job_wrapper? ? unwrap_args : args
    end

    # @api internal
    # Shared latency math: ms ints (>= 10^10) and float secs (< 10^10)
    # both stored in `enqueued_at` historically. See spec §31.5.
    def self.latency_from(enqueued_at, now_ms = nil)
      return 0.0 if enqueued_at.nil?

      now_ms ||= ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
      enq_ms = enqueued_at < 10_000_000_000 ? enqueued_at * 1_000 : enqueued_at
      diff = (now_ms - enq_ms) / 1_000.0
      diff.negative? ? 0.0 : diff
    end

    private

    def active_job_wrapper?
      klass.is_a?(String) && (ACTIVE_JOB_WRAPPER.match?(klass) || klass == 'Sidekiq::ActiveJob::Wrapper')
    end

    def unwrap_class
      job_class = item['wrapped'] || args.dig(0, 'job_class')
      return klass unless job_class

      mailer_display(job_class) || job_class
    end

    def mailer_display(job_class)
      return nil unless ACTION_MAILER_JOBS.include?(job_class)

      mailer_args = args.dig(0, 'arguments') || []
      return nil if mailer_args.size < 2

      "#{mailer_args[0]}##{mailer_args[1]}"
    end

    def unwrap_args
      job_args = args.dig(0, 'arguments') || []
      wrapped = item['wrapped']
      return job_args unless ACTION_MAILER_JOBS.include?(wrapped)

      # ActionMailer payloads start with [mailer, method, "deliver_now", *real_args]
      job_args.drop(3)
    end

    # Parse Sidekiq's mixed time formats (Float secs, Integer ms) into Time.
    def parse_time(value)
      return nil if value.nil?

      ms = value < 10_000_000_000 ? value * 1_000 : value
      ::Time.at(ms / 1_000.0)
    end
  end
end
