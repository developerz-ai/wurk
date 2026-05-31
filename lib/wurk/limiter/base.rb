# frozen_string_literal: true

require 'json'
require 'digest'
require 'securerandom'

module Wurk
  module Limiter
    # Shared base for every limiter type. Holds the public introspection
    # contract documented in §1.5 — name / type / options / size / status /
    # reset / delete plus the `within_limit(...) { ... }` block. Subclasses
    # override the acquire path and the per-type metric/size methods.
    #
    # `status` is uniform across types (#16): `{ used:, limit:, reset_at:,
    # available? }`. Subclasses supply the three values via `build_status`;
    # Concurrent additionally merges its metric counters.
    class Base
      attr_reader :name, :options

      # `register:` defaults true so constructing a limiter publishes its
      # metadata + `lmtr-list` membership. The dashboard reconstructs limiters
      # purely to read `status` on a GET, so it passes `register: false` to
      # keep introspection side-effect-free.
      def initialize(name, register: true, **options)
        unless name.is_a?(String) && NAME_PATTERN.match?(name)
          raise ArgumentError, "limiter name must match #{NAME_PATTERN.inspect} (got #{name.inspect})"
        end

        ttl = options[:ttl] || DEFAULT_TTL
        # Spec §1.2: ttl floor of 24h. Anything tighter risks losing the
        # metadata hash mid-job and orphaning slots that read it.
        raise ArgumentError, 'ttl must be >= 86_400' if ttl < 86_400

        @name = name.dup.freeze
        @options = options
        register! if register
      end

      def type
        raise NotImplementedError
      end

      def within_limit(**, &)
        raise NotImplementedError
      end

      def size
        0
      end

      # Uniform across types (#16). Subclasses override to fill in real
      # numbers; the default reports an idle, unlimited shape.
      def status
        build_status(used: 0, limit: nil, reset_at: nil)
      end

      def reset
        Wurk::Limiter.redis do |c|
          state_keys.each { |k| c.call('DEL', k) }
        end
      end

      def delete
        Wurk::Limiter.redis do |c|
          (state_keys + [meta_key]).each { |k| c.call('DEL', k) }
          c.call('SREM', LIST_KEY, @name)
        end
      end

      # Stable fingerprint for the limiter — Sidekiq 8.0+ switched from
      # SHA1 → SHA256 (~10% larger encoding). Web UI groups limiters by
      # this so that interpolated names (`stripe-#{user_id}`) get a single
      # row per shape.
      def fingerprint
        @fingerprint ||= Digest::SHA256.hexdigest("#{type}|#{@name}|#{JSON.dump(serializable_options)}")
      end

      protected

      # Assemble the uniform status hash. `available?` is derived: an
      # unlimited (nil) limit is always available; otherwise headroom remains
      # while `used < limit`. `reset_at` is an epoch-seconds Float (or nil
      # when the type has no clock-driven reset).
      def build_status(used:, limit:, reset_at:)
        { used: used, limit: limit, reset_at: reset_at,
          available?: limit.nil? || used < limit }
      end

      def meta_key
        "lmtr:#{@name}"
      end

      def state_keys
        []
      end

      def serializable_options
        @options.transform_values do |v|
          case v
          when Proc then '<proc>'
          when Symbol, Numeric, String, true, false, nil then v
          else v.to_s
          end
        end
      end

      def register!
        Wurk::Limiter.redis do |c|
          c.call('SADD', LIST_KEY, @name)
          c.call(
            'HSET', meta_key,
            'type', type.to_s,
            'options', JSON.dump(serializable_options),
            'fingerprint', fingerprint
          )
          c.call('EXPIRE', meta_key, @options[:ttl])
        end
      end

      def ttl
        @options[:ttl]
      end

      # Stable random slot id (Concurrent) / nonce (Window). 16 hex chars
      # = 8 bytes — wide enough to avoid collision under any realistic
      # burst and short enough to keep ZSET memory bounded.
      def random_id
        SecureRandom.hex(8)
      end

      def lua(name, keys:, argv:)
        Wurk::Limiter.redis do |c|
          Wurk::Lua::Loader.eval_cached(c, name, keys: keys, argv: argv)
        end
      end
    end
  end
end
