# frozen_string_literal: true

require_relative 'redis_pool'
require_relative 'middleware/chain'
require_relative 'fetcher/reliable'

module Wurk
  # One processing unit: a set of threads + queues sharing a fetcher and a
  # Redis pool. Configurations can hold many capsules; each maps to its own
  # Manager and Processors.
  #
  # Spec: docs/target/sidekiq-free.md §5 (Sidekiq::Capsule).
  class Capsule
    MODES = %i[strict weighted random].freeze

    attr_reader :name, :queues, :mode, :weights, :config
    attr_accessor :concurrency, :fetcher

    def initialize(name, config)
      @name = name.to_s
      @config = config
      @concurrency = config[:concurrency] || 5
      @queues = ['default']
      @mode = :strict
      @weights = { 'default' => 0 }
      @fetcher = nil
      @redis_pool = nil
      @local_redis_pool = nil
      @client_chain = nil
      @server_chain = nil
    end

    def to_h
      { concurrency: @concurrency, mode: @mode, weights: @weights }
    end

    # Parses queue specs Sidekiq-style:
    #   %w[high default low]        → mode :strict,   weights all 0
    #   %w[high,3 default,2 low,1]  → mode :weighted, weights {q=>w}
    #   %w[a,1 b,1 c,1]             → mode :random,   weights all 1
    # @queues is expanded by weight so a uniform shuffle gives weighted
    # fairness (e.g. ["high","high","high","default","default","low"]).
    def queues=(val)
      parsed = Array(val).map { |entry| parse_queue_entry(entry) }
      raise ArgumentError, 'queues cannot be empty' if parsed.empty?

      @weights = parsed.to_h
      @mode = detect_mode(parsed)
      @queues = expand_by_weight(parsed, @mode)
    end

    # Lossless `name[,weight]` specs (unlike `queues`, which is the
    # weight-expanded list). Lets Configuration#topology rebuild a slot that
    # round-trips back through `queues=` without flattening weights.
    def queue_specs
      @weights.map { |q, w| w.positive? ? "#{q},#{w}" : q }
    end

    # Materialize everything that lazy-inits via `||=` and default the fetcher,
    # BEFORE Configuration#freeze! freezes the capsule — otherwise the first
    # post-freeze access (a fetch tick, a middleware call) hits a nil fetcher
    # or FrozenErrors building a pool. The swarm's ChildBoot used to do this
    # by hand; centralizing it here covers the standalone CLI and embedded
    # paths too (the bug behind a nil `fetcher` in `exe/wurk`). Idempotent.
    def prepare!
      @fetcher ||= build_fetcher
      redis_pool
      local_redis_pool
      client_middleware
      server_middleware
      self
    end

    def client_middleware
      chain = (@client_chain ||= @config.client_middleware.copy_for(self))
      yield chain if block_given?
      chain
    end

    def server_middleware
      # copy_for(self) — not dup — binds the chain's `@config` to this capsule,
      # so middleware that reach for `redis_pool`/`redis`/`logger` resolve them
      # instead of hitting `nil` (a plain dup leaves @config nil).
      chain = (@server_chain ||= @config.server_middleware.copy_for(self))
      yield chain if block_given?
      chain
    end

    # Pool size = concurrency + POOL_OVERHEAD. Every processor thread can
    # be parked in a blocking BLMOVE (reliable fetch), holding its slot
    # for ~3s. POOL_OVERHEAD reserves connections for the Launcher's
    # heartbeat thread + the Scheduled::Poller so they can never be
    # starved by busy fetchers. Without this, concurrency=1 deadlocks
    # immediately (worker holds the only slot, heartbeat times out).
    POOL_OVERHEAD = 2

    def redis_pool
      @redis_pool ||= build_pool(size: @concurrency + POOL_OVERHEAD, name: "#{@name}-main")
    end

    def local_redis_pool
      @local_redis_pool ||= build_pool(size: @concurrency, name: "#{@name}-local")
    end

    # Disconnect and drop cached pools. Called by Wurk::Swarm just before
    # fork (parent side: close inherited sockets) and just after fork
    # (child side: rebuild lazily). Connection_pool#shutdown is terminal,
    # so dropping the reference is required — `redis_pool` will rebuild.
    def reset_redis_pools!
      @redis_pool&.disconnect!
      @redis_pool = nil
      @local_redis_pool&.disconnect!
      @local_redis_pool = nil
    end

    def redis(&)
      redis_pool.with(&)
    end

    def lookup(name)
      @config.lookup(name)
    end

    # Empty-poll BLMOVE backoff for this capsule's reliable fetcher (Pro
    # super_fetch §3.3). nil → the fetcher falls back to its TIMEOUT default.
    def fetch_poll_interval
      @config[:fetch_poll_interval]
    end

    def logger
      @config.logger
    end

    # No-op in OSS. Reserved for Pro/Ent hooks that need to flush per-capsule
    # state on shutdown. Manager#stop invokes this in `ensure` so the contract
    # is honored regardless of how stop unwinds.
    #
    # Spec: docs/target/sidekiq-free.md §5.
    def stop; end

    private

    # Drop-in fetch pluggability (spec §5 / §4.1): instantiate
    # `config[:fetch_class]` when the host set one — a custom or Pro fetcher —
    # else the default reliable BLMOVE fetcher (`Sidekiq::BasicFetch`). A
    # `config[:fetch_setup]` callable, if present, is handed the freshly built
    # fetcher so it can configure it before the manager starts pulling work.
    def build_fetcher
      klass = @config[:fetch_class] || Wurk::Fetcher::Reliable
      fetcher = klass.new(self)
      setup = @config[:fetch_setup]
      setup.call(fetcher) if setup.respond_to?(:call)
      fetcher
    end

    # Accepts both the CLI/string form (`"name"` / `"name,weight"`) and the
    # nested-array form Sidekiq's YAML produces for weighted queues
    # (`:queues: - [critical, 2]` parses to `["critical", 2]`). Without the Array
    # branch a real sidekiq.yml crashes at boot with `Integer(): " 2]"` (#241).
    def parse_queue_entry(entry)
      if entry.is_a?(::Array)
        raise ArgumentError, "queue entry must be `[name]` or `[name, weight]`: `#{entry}`" if entry.size > 2

        return parse_pair_queue_entry(entry[0], entry[1], entry)
      end

      qname, weight_str = entry.to_s.split(',', 2)
      parse_pair_queue_entry(qname, weight_str, entry)
    end

    def parse_pair_queue_entry(name, weight, entry)
      qname = name.to_s.strip
      raise ArgumentError, "queue name cannot be empty: `#{entry}`" if qname.empty?
      return [qname, 0] if weight.nil?

      weight = Integer(weight)
      raise ArgumentError, "queue weight must be > 0: `#{entry}`" if weight <= 0

      [qname, weight]
    end

    def detect_mode(parsed)
      weights = parsed.map(&:last)
      if weights.all?(&:zero?)
        :strict
      elsif weights.uniq.size == 1
        :random
      else
        :weighted
      end
    end

    def expand_by_weight(parsed, mode)
      return parsed.map(&:first) if %i[strict random].include?(mode)

      parsed.flat_map { |q, w| [q] * w }
    end

    def build_pool(size:, name:)
      cfg = @config.redis_config
      RedisPool.new(
        size: size,
        url: cfg[:url] || RedisPool::DEFAULT_URL,
        timeout: cfg[:timeout] || RedisPool::DEFAULT_TIMEOUT,
        name: name
      )
    end
  end
end
