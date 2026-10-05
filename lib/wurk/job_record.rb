# frozen_string_literal: true

require 'base64'
require 'zlib'
require_relative 'redact'

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
    AJ_PREFIX = '_aj_'
    AJ_GLOBALID = '_aj_globalid'

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
      @queue = queue_name
    end

    def queue = @queue || item['queue']

    # Lazily parsed payload. Memoized; never re-parses. Invalid JSON reads as
    # an empty hash whose raw bytes become `args`, as upstream does, so one
    # corrupt payload can't break a dashboard page or a Queue#each walk.
    def item
      @item ||= begin
        Wurk.load_json(@value)
      rescue ::JSON::ParserError
        @invalid_args = [@value]
        {}
      end
    end

    # Lazily serialized payload. When constructed from a Hash, we
    # generate JSON on first call so `delete` (LREM) has exact bytes.
    def value
      @value ||= Wurk.dump_json(@item)
    end

    def klass         = item['class']
    def jid           = item['jid']
    def bid           = item['bid']

    def args
      parsed = item
      @invalid_args || parsed['args']
    end

    # IterableJob progress for this job, or nil for a non-iterable job (no
    # `it-<jid>` HASH). Spec §19.3. Reads via the IterableJobQuery data API.
    def iterable_state
      return nil if jid.nil? || jid.to_s.empty?

      Wurk::IterableJobQuery.new([jid])[jid]
    end

    def tags          = item['tags'] || []
    def enqueued_at   = parse_time(item['enqueued_at'])
    # Falls back to enqueued_at as upstream does; nil (not upstream's epoch 0)
    # only when both are absent, so a dashboard shows "unknown", not 1970.
    def created_at    = parse_time(item['created_at'] || item['enqueued_at'])
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
      JobRecord.latency_from(item['enqueued_at'] || item['created_at'])
    end

    # Removes exactly this payload's bytes from the queue list. Returns
    # true when LREM removed ≥1 entry. Idempotent. Method name is
    # Sidekiq wire-compat — renaming would break `JobRecord#delete`.
    def delete
      removed = Wurk.redis { |c| c.call('LREM', Keys.queue(@queue), 1, value) }
      removed.to_i.positive?
    end

    # ActiveJob/ActionMailer unwrappers — UI-facing only. For plain Wurk
    # workers, returns the raw class name.
    def display_class
      return @display_class if defined?(@display_class)

      @display_class = item['display_class'] || (active_job_wrapper? ? unwrap_class : klass)
    end

    # UI-facing args. Encrypted jobs (§4.7) get their envelope last arg
    # masked as "[encrypted data]" so ciphertext never reaches the dashboard;
    # redaction keys off the envelope shape, so it fires whether or not the
    # stored hash carried the `encrypt` flag. Cleartext preceding args stay
    # visible for triage. Display-only — the stored payload is untouched.
    #
    # A host `redact_args` hook (Wurk::Redact) replaces all of that: it sees
    # the whole job and decides what is shown. This is the single choke point
    # for every surface that renders a job — dashboard JSON, search, the /v1
    # machine API, Sidekiq::Web-style views.
    def display_args
      return @display_args if defined?(@display_args)

      hook = Wurk::Redact.hook
      return @display_args = Wurk::Redact.args(item, hook) if hook

      base = active_job_wrapper? ? unwrap_args : args
      @display_args = Wurk::Encryption.redact_args('args' => base, 'encrypt' => item['encrypt'])
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

    # ActiveJob serializes GlobalID args as {"_aj_globalid" => gid} and tags
    # hashes with `_aj_*` bookkeeping keys; upstream shows the gid string and
    # drops the bookkeeping. ActionMailer payloads lead with
    # [mailer, method, "deliver_now"]; MailDeliveryJob's real args are the
    # trailing {"params", "args"} hash.
    def unwrap_args
      job_args = deserialize_aj(args.dig(0, 'arguments') || [])
      case item['wrapped']
      when *ACTION_MAILER_JOBS then mailer_args(item['wrapped'], job_args.drop(3))
      else job_args
      end
    end

    def mailer_args(wrapped, rest)
      return rest unless wrapped == 'ActionMailer::MailDeliveryJob' && rest.first.is_a?(Hash)

      rest.first.values_at('params', 'args')
    end

    def deserialize_aj(arg)
      case arg
      when Array then arg.map { |a| deserialize_aj(a) }
      when Hash
        return arg[AJ_GLOBALID] if arg.size == 1 && arg.key?(AJ_GLOBALID)

        arg.reject { |k, _| k.start_with?(AJ_PREFIX) }.transform_values { |v| deserialize_aj(v) }
      else arg
      end
    end

    # Parse Sidekiq's mixed time formats (Float secs, Integer ms) into a UTC
    # Time, whatever the branch, so callers never see the host's zone.
    # Integer ms is split into whole seconds + ms rather than divided as a
    # Float, which would round some timestamps a millisecond off.
    def parse_time(value)
      return nil if value.nil?
      return ::Time.at(value).utc if value < 10_000_000_000
      return ::Time.at(value / 1_000.0).utc unless value.is_a?(Integer)

      ::Time.at(value / 1_000, value % 1_000, :millisecond).utc
    end
  end
end
