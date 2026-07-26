# frozen_string_literal: true

require 'redis-client'

module Wurk
  # Translates a Sidekiq-shaped `config.redis` hash into the exact keyword set
  # redis-client accepts.
  #
  # Sidekiq normalizes the hash itself before handing it over
  # (`sidekiq/redis_client_adapter.rb#client_opts`), so initializers in the wild
  # carry keys redis-client has never known. Wurk used to splat the hash straight
  # into `RedisClient.config`, which surfaced as
  # `ArgumentError: unknown keyword: :network_timeout` — and only inside the
  # forked children, which build their own pools (#283). The parent booted fine,
  # the liveness probe passed, and the swarm respawn loop churned forever
  # processing zero jobs. Hence `validate!`, called from Configuration#redis= so
  # a bad hash raises in the parent where someone can actually see it.
  #
  # Reference: sidekiq 7.3 / 8.1 `client_opts` — namespace rejected,
  # size/pool_timeout dropped, `network_timeout` → `timeout`, `master_name` →
  # `name`, role/driver symbolized, `reconnect_attempts ||= 1`.
  module RedisOptions
    # Consumed by the pool layer (RedisPool / Capsule); never a socket concern.
    POOL_KEYS = %i[size name pool_name pool_timeout on_error].freeze

    # Accepted for Sidekiq parity, then dropped: Sidekiq used `logger` for its
    # own "connecting to Redis with options ..." line and `cluster_safe` to
    # unlock `:nodes`. redis-client has no keyword for either.
    IGNORED_KEYS = %i[logger cluster_safe].freeze

    # Sidekiq-only spellings this module rewrites into redis-client keywords.
    TRANSLATED_KEYS = %i[network_timeout master_name].freeze

    # The umbrella socket timeout, under both its names. `network_timeout` is
    # the redis-rb-era spelling every "widen the timeouts for a slow/remote
    # Redis" snippet still uses; `timeout` is redis-client's own.
    UMBRELLA_TIMEOUT_KEYS = %i[network_timeout timeout].freeze

    # Wurk splits the socket timeouts (#101) and passes all three explicitly, and
    # redis-client lets an explicit `read_timeout` win over `timeout` — so
    # forwarding the umbrella verbatim would silently drop the host's value.
    # Fan it out instead; a host-supplied split timeout still wins over the fan-out.
    SPLIT_TIMEOUT_KEYS = %i[connect_timeout read_timeout write_timeout].freeze

    # Symbols in redis-client, strings in plenty of YAML-sourced configs.
    SYMBOLIZED_KEYS = %i[driver role].freeze

    # Keys that mean something in Sidekiq but have no Wurk equivalent. Raise
    # naming the key and its replacement — the alternative is an opaque
    # `unknown keyword:` from three layers down inside a forked child.
    REJECTED_KEYS = {
      namespace: 'Redis namespacing was dropped in Sidekiq 7 and Wurk never implemented it ' \
                 '(docs/migrate-from-sidekiq.md §4). Give Wurk its own Redis database ' \
                 '(redis://host:6379/1) or its own instance instead.',
      nodes: 'Wurk does not run on Redis Cluster. Point config.redis at a single server with ' \
             '`url:`, or at a Sentinel set with `sentinels:`.'
    }.freeze

    # Keyword parameter kinds in Method#parameters.
    KEYWORD_PARAMS = %i[key keyreq].freeze

    class << self
      # The keyword hash for RedisClient.config / RedisClient.sentinel.
      # `defaults` are Wurk's own socket defaults; everything the host supplied
      # wins over them.
      def normalize(options, defaults: {})
        opts = symbolize(options)
        validate!(opts)
        opts = translate(opts)

        # A default `url` is meaningless next to a sentinel set and actively
        # harmful: SentinelConfig derives the master name and db from it.
        defaults = defaults.except(:url) if sentinel?(opts)

        defaults.merge(split_timeouts(opts), opts.except(*UMBRELLA_TIMEOUT_KEYS))
      end

      # Raises for anything redis-client would reject. Cheap and pure, so it runs
      # in the parent (Configuration#redis=) as well as at pool-build time.
      def validate!(options)
        opts = symbolize(options)

        REJECTED_KEYS.each do |key, hint|
          raise ArgumentError, "config.redis[:#{key}] is not supported. #{hint}" if opts.key?(key)
        end

        unknown = opts.keys - known_keys
        return if unknown.empty?

        raise ArgumentError,
              "config.redis: unknown option#{'s' if unknown.size > 1} " \
              "#{unknown.map(&:inspect).join(', ')}. Supported keys: #{known_keys.sort.join(', ')}."
      end

      # Sentinel sets go through RedisClient.sentinel — RedisClient.config
      # rejects `sentinels:` outright. Same routing Sidekiq does.
      def sentinel?(client_config)
        client_config.key?(:sentinels)
      end

      # Every keyword redis-client itself accepts, read off its own signatures so
      # the list can't drift from the installed version. Config#initialize takes
      # a **kwargs rest and forwards to Config::Common, so both have to be walked;
      # SentinelConfig adds the sentinel-only keys.
      def known_keys
        @known_keys ||= [
          ::RedisClient::Config, ::RedisClient::Config::Common, ::RedisClient::SentinelConfig
        ].flat_map { |mod| keyword_params(mod) }.union(POOL_KEYS, IGNORED_KEYS, TRANSLATED_KEYS)
      end

      private

      # Drop what redis-client has no keyword for, then rewrite the Sidekiq
      # spellings it does have an equivalent for.
      def translate(opts)
        opts = opts.except(*POOL_KEYS, *IGNORED_KEYS)
        opts[:name] = opts.delete(:master_name) if opts.key?(:master_name)
        SYMBOLIZED_KEYS.each { |key| opts[key] = opts[key].to_sym if opts[key] }
        opts
      end

      def keyword_params(mod)
        mod.instance_method(:initialize).parameters.filter_map do |kind, key|
          key if KEYWORD_PARAMS.include?(kind)
        end
      end

      # The umbrella timeout fanned out across the three split ones. Returns {}
      # when the host set neither, leaving Wurk's defaults in place.
      def split_timeouts(opts)
        umbrella = opts.values_at(*UMBRELLA_TIMEOUT_KEYS).compact.first
        return {} unless umbrella

        SPLIT_TIMEOUT_KEYS.to_h { |key| [key, umbrella] }
      end

      def symbolize(options)
        options.transform_keys(&:to_sym)
      end
    end
  end
end
