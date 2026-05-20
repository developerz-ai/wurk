# frozen_string_literal: true

require_relative 'redis_pool'
require_relative 'middleware/chain'

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

    def client_middleware
      chain = (@client_chain ||= @config.client_middleware.dup)
      yield chain if block_given?
      chain
    end

    def server_middleware
      chain = (@server_chain ||= @config.server_middleware.dup)
      yield chain if block_given?
      chain
    end

    def redis_pool
      @redis_pool ||= build_pool(size: @concurrency, name: "#{@name}-main")
    end

    def local_redis_pool
      @local_redis_pool ||= build_pool(size: @concurrency, name: "#{@name}-local")
    end

    def redis(&)
      redis_pool.with(&)
    end

    def lookup(name)
      @config.lookup(name)
    end

    def logger
      @config.logger
    end

    private

    def parse_queue_entry(entry)
      qname, weight = entry.to_s.split(',', 2)
      weight = weight.nil? ? 0 : Integer(weight)
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

      parsed.flat_map { |q, w| [q] * [w, 1].max }
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
