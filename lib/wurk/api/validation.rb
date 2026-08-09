# frozen_string_literal: true

require 'json'
require_relative 'problem'

module Wurk
  module API
    # Everything the API refuses at its boundary, before a Wurk object sees it.
    #
    # Client validates a job hash written by Ruby running in this process. This
    # validates one typed by a stranger, and the two are different jobs.
    # `JobUtil::TRANSIENT_ATTRIBUTES` (job_util.rb) is a *strip*-list: it names
    # the two keys that must never reach the wire and passes everything else
    # through, which is the right default for a producer that already runs your
    # code and the wrong one for a producer that doesn't. So the allow-list
    # JobUtil has no reason to own lives here, at the only door a stranger can
    # knock on.
    #
    # Nothing in this file changes what a Ruby `perform_async` may push. The
    # boundary is the HTTP request, not the payload format — wire-compat is
    # untouched.
    module Validation
      # Carries the problem it should be rendered as, so a route rescues one
      # class and renders whatever it was handed instead of mapping message
      # text back onto a status code.
      class Invalid < StandardError
        attr_reader :type, :status, :extra

        def initialize(detail, type: Problem::INVALID_REQUEST, status: 400, **extra)
          super(detail)
          @type = type
          @status = status
          @extra = extra
        end
      end

      # A Ruby constant path and nothing else. `class` reaches the consumer as
      # a constantize plus `new.perform`, so the string is a code selector, not
      # data: any shape that is not a constant path is either an attack or a
      # bug, and both are better answered here than by a NameError in a worker
      # process two hosts away.
      #
      # Linear, not backtracking: `:` is outside the character class, so each
      # `::` boundary is unambiguous.
      CLASS_FORMAT = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/

      # Length is checked separately from shape so a megabyte of `A`s is
      # refused on a fact about the string rather than matched, stored in a
      # payload and echoed back in an error.
      MAX_CLASS_LENGTH = 255

      # A jid reaches Redis as a ZSCAN glob (JobSet#find_job wraps it in `*`),
      # so an unbounded or metacharacter-carrying jid off the network is a scan
      # this API runs on the client's behalf. Sidekiq's own jids are
      # `SecureRandom.hex(12)`; admit any URL-safe token of a sane length and
      # refuse the rest at the door.
      JID_FORMAT = /\A[A-Za-z0-9_-]{1,255}\z/

      # A queue name arrives as one path segment (percent-decoded by the
      # router, so a name containing '/' is reachable) and reaches Redis as
      # `queue:<name>`. The Sidekiq schema bounds it nowhere, so this door
      # does: whitespace and control characters are out because a name
      # carrying them is one no operator can type back into the dashboard or a
      # CLI flag, and the length cap exists for the same reason a jid's does —
      # it is echoed back on every listing.
      QUEUE_NAME_FORMAT = /\A[^[:space:][:cntrl:]]{1,255}\z/

      # A process identity is `<hostname>:<pid>:<nonce>` and is itself a Redis
      # key — the heartbeat HASH, `<identity>:work` and `<identity>-signals`
      # are all built by interpolating it. The same shape as a queue name for
      # the same reason, spelled separately because the two doors are
      # independent: bounding what may be addressed as a queue says nothing
      # about what may be addressed as a process.
      IDENTITY_FORMAT = /\A[^[:space:][:cntrl:]]{1,255}\z/

      # Same word the router uses for "any scope": here it turns the class
      # allow-list off.
      ANY = :any

      # The top-level keys a job hash may carry in over HTTP.
      #
      # Anything absent is refused rather than dropped: a silently ignored
      # `deadlin:` typo is a job that runs unbounded and a producer that never
      # finds out. The server-written fields are absent on purpose —
      # `created_at`/`enqueued_at` would let a client backdate its own queue
      # latency, `retry_count`/`failed_at` would let it lie to the retrier,
      # `expiry`/`deadline_at` are stamps derived from `expires_in`/`deadline`,
      # `bid` would attach a job to a batch whose `pending` counter was never
      # incremented for it, and `pool`/`client_class` name Ruby objects a JSON
      # body cannot hold at all.
      #
      # Mutable for the same reason `TRANSIENT_ATTRIBUTES` is: a gem that adds
      # a job option (sidekiq-unique-jobs' `lock:`) has to be able to append
      # one without reopening this file. Baked into the literal rather than
      # appended at load, so the parallel test runner never observes a
      # half-built list.
      # rubocop:disable Style/MutableConstant
      JOB_KEYS = %w[
        class args queue at retry jid backtrace tags dead
        retry_for retry_queue expires_in track timeout deadline
        encrypt unique_for unique_until collapse log_level locale wrapped
      ]
      # rubocop:enable Style/MutableConstant

      # `push_bulk`'s envelope keys, on top of the job keys it shares.
      BULK_KEYS = %w[batch_size spread_interval].freeze

      # Echoing a rejected key back is the only way a client finds its typo,
      # but the keys came off the network — bound how many and how long, for
      # the same reason the JSON parser's own message is never forwarded.
      MAX_REPORTED_KEYS = 10
      MAX_REPORTED_KEY_LENGTH = 40

      module_function

      # Reads at most `limit + 1` bytes, so an oversized body is refused on the
      # strength of what a cap-sized read already proved rather than by
      # buffering the whole thing to measure it.
      def body!(request, limit)
        raw = request.read_body(limit + 1)
        return raw unless raw.bytesize > limit

        raise Invalid.new(
          "The request body may not exceed #{limit} bytes.",
          type: Problem::PAYLOAD_TOO_LARGE, status: 413, max_bytes: limit
        )
      end

      # The body is the job hash with no envelope around it, so this only
      # insists it is a JSON object at all — everything downstream indexes it
      # by key.
      def object!(raw)
        parsed = ::JSON.parse(raw)
        raise Invalid, 'The request body must be a JSON object.' unless parsed.is_a?(::Hash)

        parsed
      rescue ::JSON::ParserError
        # Deliberately not the parser's own message: it quotes the unparsed
        # remainder of the document, so a large malformed body would come back
        # as a large error.
        raise Invalid, 'The request body is not valid JSON.'
      end

      # One job hash, for `POST /jobs`.
      def job!(payload, principal:, config:)
        known_keys!(payload, JOB_KEYS)
        jid!(payload['jid']) if payload.key?('jid')
        allowed!(class!(payload), principal, config) if payload.key?('class')
        args_size!(payload['args'], config.api_max_args_bytes)
        payload
      end

      # The `push_bulk` envelope, for `POST /jobs/bulk`: the same job keys plus
      # the two that describe the batch, and an `args` that is one array per
      # job rather than one array of arguments.
      def bulk!(payload, principal:, config:)
        known_keys!(payload, JOB_KEYS + BULK_KEYS)
        jid!(payload['jid']) if payload.key?('jid')
        allowed!(class!(payload), principal, config) if payload.key?('class')
        bulk_args_size!(payload['args'], config.api_max_args_bytes)
        payload
      end

      # @raise [Invalid] unless `jid` is a URL-safe token of a sane length.
      # @return [String] the jid.
      def jid!(jid) = url_safe!(jid, 'jid')

      # A bid indexes `b-<bid>` and its satellite keys, and Batch::Status
      # builds every one of them by interpolation — the same key-fragment
      # exposure a jid has, so the same door.
      # @return [String] the bid.
      def bid!(bid) = url_safe!(bid, 'batch id')

      def url_safe!(value, label)
        return value if value.is_a?(::String) && JID_FORMAT.match?(value)

        raise Invalid, "A #{label} is a URL-safe token of up to 255 characters."
      end

      # @raise [Invalid] unless `name` fits {QUEUE_NAME_FORMAT}.
      # @return [String] the queue name.
      def queue_name!(name)
        return name if name.is_a?(::String) && QUEUE_NAME_FORMAT.match?(name)

        raise Invalid, 'A queue name is up to 255 characters with no whitespace or control characters.'
      end

      # @raise [Invalid] unless `identity` fits {IDENTITY_FORMAT}.
      # @return [String] the process identity.
      def identity!(identity)
        return identity if identity.is_a?(::String) && IDENTITY_FORMAT.match?(identity)

        raise Invalid, 'A process identity is up to 255 characters with no whitespace or control characters.'
      end

      # Validates the allow-list where it is declared, so a typo'd class name
      # raises in the initializer that wrote it instead of 403ing a producer in
      # production. Accepts Classes as well as names — a host listing the
      # constant it already has in scope is spelling the same thing.
      #
      # @return [Array<String>, :any, nil] normalized allow-list.
      def enqueueable_classes!(classes)
        return nil if classes.nil?
        return ANY if classes == ANY

        list = Array(classes).map(&:to_s)
        raise ArgumentError, 'api_enqueue_classes must name at least one class, :any, or nil' if list.empty?

        unknown = list.reject { |name| class_name?(name) }
        raise ArgumentError, "api_enqueue_classes entries must be Ruby class names: #{unknown.inspect}" if unknown.any?

        list.freeze
      end

      def class_name?(value)
        value.is_a?(::String) && value.length <= MAX_CLASS_LENGTH && CLASS_FORMAT.match?(value)
      end

      def known_keys!(payload, allowed)
        unknown = payload.keys - allowed
        return if unknown.empty?

        reported = reportable(unknown)
        raise Invalid.new("Unknown job keys: #{reported.join(', ')}.", unknown_keys: reported)
      end

      def reportable(keys)
        keys.sort.first(MAX_REPORTED_KEYS).map { |key| key.to_s[0, MAX_REPORTED_KEY_LENGTH] }
      end

      def class!(payload)
        job_class = payload['class']
        return job_class if class_name?(job_class)

        raise Invalid, %(Job 'class' must be a Ruby class name, e.g. "HardWorker" or "Billing::Charge".)
      end

      # The allow-list JobUtil has no reason to own:
      #
      #   nil   → only an `admin` token may enqueue, and it may enqueue anything
      #   Array → exactly these names, for every token, `admin` included
      #   :any  → the check is off
      #
      # Unset denies an enqueue-scoped producer everything, because `class`
      # selects which of the host's jobs runs and a producer that can name any
      # constant is choosing. `admin` is exempt only while no list exists: it
      # already holds the destructive routes, so restricting which class it may
      # enqueue would be theatre. Once a host writes a list, it means it.
      def allowed!(job_class, principal, config)
        return if enqueueable?(job_class, principal, config.api_enqueue_classes)

        raise Invalid.new(
          "#{job_class} may not be enqueued over HTTP; config.api_enqueue_classes names the classes that may.",
          type: Problem::CLASS_NOT_ALLOWED, status: 403, job_class: job_class
        )
      end

      def enqueueable?(job_class, principal, classes)
        case classes
        when nil then principal.permits?(:admin)
        when ANY then true
        else classes.include?(job_class)
        end
      end

      # Only an Array is sizeable and only an Array is legal; Client names the
      # other shapes, with the offending value in the message.
      def args_size!(args, limit)
        return unless args.is_a?(::Array)

        size = ::JSON.generate(args).bytesize
        return if size <= limit

        raise Invalid.new(
          "Job args may not exceed #{limit} bytes; these serialize to #{size}.",
          type: Problem::PAYLOAD_TOO_LARGE, status: 413, max_bytes: limit
        )
      end

      # The body cap bounds the request; this bounds each job the request turns
      # into, which for a bulk push is the only one of the two that bounds what
      # lands in Redis.
      def bulk_args_size!(args, limit)
        return unless args.is_a?(::Array)

        args.each_with_index do |job_args, index|
          next unless job_args.is_a?(::Array)

          size = ::JSON.generate(job_args).bytesize
          next if size <= limit

          raise Invalid.new(
            "Job #{index}'s args may not exceed #{limit} bytes; they serialize to #{size}.",
            type: Problem::PAYLOAD_TOO_LARGE, status: 413, max_bytes: limit, job_index: index
          )
        end
      end
    end
  end
end
