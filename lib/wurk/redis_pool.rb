# frozen_string_literal: true

require 'redis-client'
require 'connection_pool'

module Wurk
  # Per-process pool over redis-client + connection_pool. Never share a socket
  # across forks: the parent closes the pool before fork, each child opens a
  # fresh one (see docs/idea/03-process-model.md, steps 3 and 5).
  #
  # Retry policy on conn-level errors: close + retry once for messages
  # prefixed READONLY / NOREPLICAS / UNBLOCKED. Spec: docs/target/sidekiq-free.md §26.
  class RedisPool
    DEFAULT_URL     = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
    DEFAULT_TIMEOUT = 1.0
    DEFAULT_NAME    = 'default'

    # Server-side messages where Sidekiq (and therefore Wurk) closes the
    # connection and retries the block exactly once. Any other RedisClient::Error
    # propagates immediately.
    RETRYABLE_MSG = /\A(READONLY|NOREPLICAS|UNBLOCKED)/

    attr_reader :size, :url, :timeout, :name

    def initialize(size:, url: DEFAULT_URL, timeout: DEFAULT_TIMEOUT, name: DEFAULT_NAME)
      @size    = size
      @url     = url
      @timeout = timeout
      @name    = name
      @pool    = ConnectionPool.new(size: size, timeout: timeout) { build_client }
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

    def build_client
      RedisClient.config(url: @url, timeout: @timeout).new_client
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
