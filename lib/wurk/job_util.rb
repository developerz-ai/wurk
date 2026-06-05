# frozen_string_literal: true

require 'json'
require 'securerandom'

module Wurk
  # Mixin shared by Wurk::Client (and Wurk::Job::Setter) to validate, normalize,
  # and JSON-verify job payloads before they hit Redis.
  #
  # Spec: docs/target/sidekiq-free.md §9 (Sidekiq::JobUtil).
  module JobUtil # rubocop:disable Metrics/ModuleLength
    # Top-level keys consumed at enqueue time but stripped from every payload
    # before raw_push. `pool` selects the Redis pool (resolved in client_push /
    # build_client) and must never reach the wire — spec §2.2 marks it transient.
    # Mutable so Pro/Ent/extension code (e.g. TransactionAwareClient adding
    # "client_class") can append at load time without monkey-patching.
    TRANSIENT_ATTRIBUTES = ['pool'] # rubocop:disable Style/MutableConstant

    RETRY_FOR_MAX = 1_000_000_000

    # @raise [ArgumentError] if the payload is structurally invalid.
    def validate(item)
      raise(ArgumentError, "Job must be a Hash with 'class' and 'args' keys: `#{item}`") unless valid_shape?(item)
      raise(ArgumentError, "Job args must be an Array: `#{item}`") unless item['args'].is_a?(Array)
      raise(ArgumentError, "Job class must be a Class or String: `#{item}`") unless valid_class?(item['class'])
      raise(ArgumentError, "Job 'at' must be a Numeric timestamp: `#{item}`") unless valid_at?(item)
      raise(ArgumentError, "Job tags must be an Array: `#{item}`") unless valid_tags?(item)
      return if valid_retry_for?(item)

      raise(ArgumentError, "Job retry_for over #{RETRY_FOR_MAX} is unreasonable: `#{item}`")
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
      normalized
    end

    # Pro `expires_in:` → absolute epoch-float `expiry` resolved once at push,
    # so the server middleware doesn't redo the math. Spec: sidekiq-pro.md §7.
    # nil.respond_to?(:to_f) is true on modern Ruby (returns 0.0), so we must
    # gate on a non-nil duration before coercing.
    def stamp_expiry(item)
      d = item['expires_in']
      return if d.nil?

      item['expiry'] ||= (item['created_at'].to_f / 1000.0) + d.to_f if d.respond_to?(:to_f)
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

    # Returns the first offending value, or nil when the tree is JSON-native.
    def json_unsafe(obj)
      case obj
      when String, Integer, Float, TrueClass, FalseClass, NilClass then nil
      when Array then json_unsafe_array(obj)
      when Hash then json_unsafe_hash(obj)
      else obj
      end
    end

    def json_unsafe_array(arr)
      arr.each do |v|
        bad = json_unsafe(v)
        return bad unless bad.nil?
      end
      nil
    end

    def json_unsafe_hash(hash)
      hash.each do |k, v|
        return k unless k.is_a?(String)

        bad = json_unsafe(v)
        return bad unless bad.nil?
      end
      nil
    end
  end
end
