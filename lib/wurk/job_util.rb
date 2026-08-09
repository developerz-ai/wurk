# frozen_string_literal: true

require 'json'
require 'securerandom'

module Wurk
  # Mixin shared by Wurk::Client (and Wurk::Job::Setter) to validate, normalize,
  # and JSON-verify job payloads before they hit Redis.
  #
  # Spec: docs/target/sidekiq-free.md §9 (Sidekiq::JobUtil).
  module JobUtil
    # Top-level keys consumed at enqueue time but stripped from every payload
    # before raw_push — they must never reach the wire (spec §2.2):
    #   `pool`         selects the Redis pool (resolved in client_push/build_client)
    #   `client_class` swaps the enqueue client (Wurk.transactional_push!)
    # Both carry non-JSON values (a pool / a Class). Baked into the literal rather
    # than appended at load: a load-time `<<` is fragile under the parallel test
    # runner (a test that add/deletes the same key clobbers it for later suites).
    # Still mutable so other extensions can append without monkey-patching.
    TRANSIENT_ATTRIBUTES = %w[pool client_class] # rubocop:disable Style/MutableConstant

    RETRY_FOR_MAX = 1_000_000_000

    # The only values `track` (the Wurk::Status opt-in) may hold. Checked
    # rather than coerced because {Wurk::Status.tracked?} asks the payload for
    # truthiness: `track: 'false'` would track every job of the class, and
    # `track: :maybe` would too. Both read as "off" to whoever wrote them and
    # cost a Redis row per job until someone goes looking in the key space.
    TRACK_VALUES = [true, false, nil].freeze

    # Both doors `track` can come through — a class-level `sidekiq_options`
    # (worker or ActiveJob) and a raw payload push — end up here, so the two
    # DSL copies stay in sync by calling the same check rather than repeating
    # it. Rejected where it was written, not where it is read.
    #
    # @raise [ArgumentError] unless `value` is true, false, or absent.
    def self.validate_track!(value, subject)
      return if TRACK_VALUES.include?(value)

      raise(ArgumentError, "Job 'track' must be true or false: `#{subject}`")
    end

    # The two wall-clock bounds, both in seconds: `timeout` bounds one attempt,
    # `deadline` bounds the job from enqueue onward. Checked here rather than
    # where they are read, for the same reason `track` is — the reader is
    # {Wurk::Middleware::Timeout}, on a server one deploy away from whoever
    # wrote `deadline: '5 minutes'`, and its answer to a bound it cannot use is
    # to run the job unbounded, because the payload may predate the option or
    # come from stock Sidekiq. Silence is right there and useless here, so both
    # doors a Wurk-written bound comes through — a class-level `sidekiq_options`
    # (worker or ActiveJob) and a payload push — call this instead.
    BOUND_OPTIONS = %w[timeout deadline].freeze

    # @raise [ArgumentError] unless every bound present is a positive, finite
    #   number of seconds.
    def self.validate_bounds!(item)
      BOUND_OPTIONS.each do |name|
        value = item[name]
        next if value.nil? || positive_seconds?(value)

        raise(ArgumentError, "Job '#{name}' must be a positive number of seconds: `#{item}`")
      end
    end

    # The one definition of a bound Wurk can act on, shared by the check above
    # and by the middleware that arms it, so "valid where it was declared" and
    # "usable where it is read" cannot drift apart. ActiveSupport durations
    # pass: `5.minutes.is_a?(Numeric)` is true by that class's own design.
    def self.positive_seconds?(value)
      return false unless value.is_a?(::Numeric)

      seconds = value.to_f
      seconds.finite? && seconds.positive?
    end

    # @raise [ArgumentError] if the payload is structurally invalid.
    def validate(item)
      raise(ArgumentError, "Job must be a Hash with 'class' and 'args' keys: `#{item}`") unless valid_shape?(item)
      raise(ArgumentError, "Job args must be an Array: `#{item}`") unless item['args'].is_a?(Array)
      raise(ArgumentError, "Job class must be a Class or String: `#{item}`") unless valid_class?(item['class'])
      raise(ArgumentError, "Job 'at' must be a Numeric timestamp: `#{item}`") unless valid_at?(item)

      validate_option_values(item)
    end

    # Walk args; report the first non-JSON-native value according to the
    # configured strict mode. Hash keys must be Strings.
    def verify_json(item)
      mode = Wurk.strict_args_mode
      return if mode == false

      offender = json_unsafe(item['args'])
      return if offender.nil?

      report_unsafe(item, offender, mode)
    end

    # Validate → merge class/default options → stringify → assign jid &
    # created_at → strip transient keys. Returns the canonical payload.
    def normalize_item(item)
      validate(item)
      normalized = class_defaults_for(item['class']).merge(item)
      normalized = wrap_options(normalized)
      stringify_identity!(normalized, item['class'])
      finalize(normalized)
    end

    def now_in_millis
      ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
    end

    private

    # The second half of #validate: the keys a caller *may* set rather than the
    # ones every job must have. Split off for the ABC ceiling alone — the two
    # halves run back to back and mean the same thing.
    def validate_option_values(item)
      raise(ArgumentError, "Job tags must be an Array: `#{item}`") unless valid_tags?(item)

      JobUtil.validate_track!(item['track'], item)
      JobUtil.validate_bounds!(item)
      return if valid_retry_for?(item)

      raise(ArgumentError, "Job retry_for over #{RETRY_FOR_MAX} is unreasonable: `#{item}`")
    end

    def valid_shape?(item) = item.is_a?(Hash) && item.key?('class') && item.key?('args')
    def valid_class?(klass) = klass.is_a?(Class) || klass.is_a?(String)
    def valid_at?(item) = !item.key?('at') || item['at'].is_a?(Numeric)
    def valid_tags?(item) = !item.key?('tags') || item['tags'].is_a?(Array)

    def valid_retry_for?(item)
      return true unless item.key?('retry_for')

      value = item['retry_for']
      parsed = numeric_retry_for(value)
      return false if parsed.nil?

      parsed <= RETRY_FOR_MAX
    end

    def numeric_retry_for(value)
      case value
      when Integer then value
      when Numeric then value.to_i
      when String then (Integer(value, 10) if value.match?(/\A-?\d+\z/))
      end
    end

    def class_defaults_for(job_class)
      respondable_class?(job_class) ? job_class.get_sidekiq_options : Wurk.default_job_options
    end

    def respondable_class?(klass)
      klass.is_a?(Class) && klass.respond_to?(:get_sidekiq_options)
    end

    def wrap_options(normalized)
      wrapped = normalized['wrapped']
      respondable_class?(wrapped) ? wrapped.get_sidekiq_options.merge(normalized) : normalized
    end

    def stringify_identity!(normalized, job_class)
      normalized['class'] = job_class.to_s
      normalized['queue'] = normalized['queue'].to_s
      return unless normalized['queue'].empty?

      raise ArgumentError, "Job must include a non-empty queue name: `#{normalized}`"
    end

    def finalize(normalized)
      TRANSIENT_ATTRIBUTES.each { |k| normalized.delete(k) }
      normalized['jid'] ||= SecureRandom.hex(12)
      normalized['retry_for'] = numeric_retry_for(normalized['retry_for']) if normalized.key?('retry_for')
      normalized['created_at'] ||= now_in_millis
      stamp_expiry(normalized)
      stamp_deadline(normalized)
      normalized
    end

    # Pro `expires_in:` → absolute epoch-float `expiry` resolved once at push,
    # so the server middleware doesn't redo the math. Spec: sidekiq-pro.md §7.
    # nil.respond_to?(:to_f) is true on modern Ruby (returns 0.0), so we must
    # gate on a non-nil duration before coercing.
    def stamp_expiry(item)
      d = item['expires_in']
      return if d.nil? || !d.respond_to?(:to_f)

      item['expiry'] ||= clock_origin(item) + d.to_f
    end

    # `deadline:` → absolute epoch-float `deadline_at`, the same conversion
    # #stamp_expiry does and, here, the thing that makes the option mean what it
    # says. A deadline is absolute: retries can't outlive it, and neither can an
    # IterableJob resuming after a cooperative interrupt. Both re-push this hash
    # and the stamp rides along on it, so every later attempt measures against
    # the first push's cutoff instead of restarting the clock — which is exactly
    # what a per-attempt `timeout` does instead, and why they are two options.
    # `||=` protects the same property against a caller that re-normalizes.
    #
    # An unusable value is left unstamped rather than raised on: both doors that
    # can write one already refused it (.validate_bounds!), so what reaches here
    # is a class default set some other way, and Middleware::Timeout's answer to
    # a bound it can't use — run the job unbounded — is the one to agree with.
    def stamp_deadline(item)
      d = item['deadline']
      return unless JobUtil.positive_seconds?(d)

      item['deadline_at'] ||= clock_origin(item) + d.to_f
    end

    # For scheduled jobs the clock origin is `at` (epoch seconds), not
    # `created_at` (epoch millis) — otherwise any delay longer than the duration
    # makes the job born-expired: perform_in(2h) + expires_in: 1h must expire at
    # 3h, and the same holds for a deadline.
    def clock_origin(item)
      item['at'] ? item['at'].to_f : (item['created_at'].to_f / 1000.0)
    end

    def report_unsafe(item, offender, mode)
      job_class = item['wrapped'] || item['class']
      msg = "Job arguments to #{job_class} must be native JSON types, " \
            "but #{offender.inspect} is a #{offender.class}. " \
            'See https://github.com/sidekiq/sidekiq/wiki/Best-Practices'
      case mode
      when :raise then raise ArgumentError, msg
      when :warn then Wurk.logger.warn(msg)
      end
    end

    JSON_NATIVE = ->(_val) {}

    # Dispatch table for the args walk, ported from Sidekiq (job_util.rb:80-111).
    # Keyed by `val.class` under `compare_by_identity`, so every node costs one
    # identity lookup + one call instead of the ladder of `Module#===` checks a
    # `case/when` compiles to — the entry node is always the args Array, which
    # sat behind six failing `===` probes.
    #
    # Identity lookup means a *subclass* of a JSON-native type misses the table
    # and falls to the default lambda, i.e. is reported unsafe: an
    # ActiveSupport::SafeBuffer arg raises where a bare String does not. That is
    # Sidekiq's behavior and the drop-in contract, not an oversight. Hash keys
    # are the one exception — they are checked with `is_a?`, so a String
    # subclass key is accepted, again matching Sidekiq.
    RECURSIVE_JSON_UNSAFE = { # rubocop:disable Style/MutableConstant -- frozen below, after the two setup calls
      Integer => JSON_NATIVE,
      Float => JSON_NATIVE,
      TrueClass => JSON_NATIVE,
      FalseClass => JSON_NATIVE,
      NilClass => JSON_NATIVE,
      String => JSON_NATIVE,
      Array => lambda { |val|
        val.each do |e|
          bad = RECURSIVE_JSON_UNSAFE[e.class].call(e)
          return bad unless bad.nil?
        end
        nil
      },
      Hash => lambda { |val|
        val.each do |k, v|
          return k unless k.is_a?(String)

          bad = RECURSIVE_JSON_UNSAFE[v.class].call(v)
          return bad unless bad.nil?
        end
        nil
      }
    }
    RECURSIVE_JSON_UNSAFE.default = ->(val) { val }
    RECURSIVE_JSON_UNSAFE.compare_by_identity
    RECURSIVE_JSON_UNSAFE.freeze
    private_constant :JSON_NATIVE, :RECURSIVE_JSON_UNSAFE

    # Returns the first offending value, or nil when the tree is JSON-native.
    def json_unsafe(obj)
      RECURSIVE_JSON_UNSAFE[obj.class].call(obj)
    end
  end
end
