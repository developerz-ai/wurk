# frozen_string_literal: true

require 'redis-client'
require 'connection_pool'
require_relative 'redis_client_adapter'

module Wurk
  # Per-process pool over redis-client + connection_pool. Never share a socket
  # across forks: the parent closes the pool before fork, each child opens a
  # fresh one (see docs/idea/03-process-model.md, steps 3 and 5).
  #
  # Retry policy on conn-level errors: close + retry once for messages
  # prefixed READONLY / NOREPLICAS / UNBLOCKED. Spec: docs/target/sidekiq-free.md §26.
  class RedisPool
    DEFAULT_URL  = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
    DEFAULT_NAME = 'default'

    # ConnectionPool checkout wait — how long #with blocks for a free slot.
    DEFAULT_POOL_TIMEOUT = 1.0

    # Socket-level timeouts handed to RedisClient, split apart from the checkout
    # wait above. read/write are deliberately wider than connect so a briefly-
    # slow-but-alive Redis (RDB fork pause, a large BLMOVE payload) doesn't
    # spuriously ReadTimeout — the production incident (#101) the single
    # dual-use timeout caused. reconnect_attempts re-dials a dropped socket once.
    DEFAULT_CONNECT_TIMEOUT    = 1.0
    DEFAULT_READ_TIMEOUT       = 2.5
    DEFAULT_WRITE_TIMEOUT      = 2.5
    DEFAULT_RECONNECT_ATTEMPTS = 1

    # Server-side messages where Sidekiq (and therefore Wurk) closes the
    # connection and retries the block exactly once. Any other RedisClient::Error
    # propagates immediately.
    RETRYABLE_MSG = /\A(READONLY|NOREPLICAS|UNBLOCKED)/

    attr_reader :size, :url, :name, :pool_timeout, :client_config

    # Takes the standard Sidekiq `config.redis` hash: `pool_timeout` tunes the
    # ConnectionPool checkout; `connect_timeout`/`read_timeout`/`write_timeout`/
    # `reconnect_attempts` plus any other key (driver, ssl_params, …) forward
    # verbatim to RedisClient.config.
    def initialize(size:, name: DEFAULT_NAME, **options)
      @size          = size
      @name          = name
      @pool_timeout  = options.fetch(:pool_timeout, DEFAULT_POOL_TIMEOUT)
      @client_config = build_client_config(options)
      @url           = @client_config[:url]
      @pool          = ConnectionPool.new(size: size, timeout: @pool_timeout) { build_client }
    end

    def with
      @pool.with do |conn|
        attempts = 0
        begin
          yield conn
        rescue RedisClient::Error => e
          raise unless RETRYABLE_MSG.match?(e.message.to_s)
          raise if attempts >= 1

          attempts += 1
          safe_close(conn)
          retry
        end
      end
    end

    def disconnect!
      @pool.shutdown { |conn| safe_close(conn) }
    end

    def info
      with { |conn| parse_info(conn.call('INFO')) }
    end

    private

    # Socket config forwarded to RedisClient.config. Host-supplied keys win over
    # the defaults; `pool_timeout` is dropped (it's a pool concern, not a socket
    # one) and unknown keys pass straight through.
    def build_client_config(options)
      {
        url: DEFAULT_URL,
        connect_timeout: DEFAULT_CONNECT_TIMEOUT,
        read_timeout: DEFAULT_READ_TIMEOUT,
        write_timeout: DEFAULT_WRITE_TIMEOUT,
        reconnect_attempts: DEFAULT_RECONNECT_ATTEMPTS
      }.merge(options.except(:pool_timeout)).freeze
    end

    # Wrapped in the CompatClient decorator so `Sidekiq.redis { |c| c.smembers }`
    # method-style commands work like Sidekiq 7+ (#204). Wurk's own code paths
    # use #call, which the decorator forwards.
    def build_client
      RedisClientAdapter::CompatClient.new(RedisClient.config(**@client_config).new_client)
    end

    def safe_close(conn)
      conn.close
    rescue StandardError
      nil
    end

    def parse_info(raw)
      raw.to_s.each_line.with_object({}) do |line, h|
        line = line.strip
        next if line.empty? || line.start_with?('#')

        key, val = line.split(':', 2)
        h[key] = val if key && val
      end
    end
  end
end
