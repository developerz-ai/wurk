# frozen_string_literal: true

require 'redis_client'
require_relative '../redis_options'

module Wurk
  module Preflight
    # The only way a preflight touches Redis. Anything outside the allowlist
    # raises before it reaches the socket, so "read-only" is enforced here rather
    # than promised by each check. LLEN is left out on purpose: sampling never
    # needs a length, and a list's length is the one read an operator's alert
    # may already key on.
    class Reader
      class Forbidden < StandardError; end

      ALLOWED = %w[INFO DBSIZE SCAN TYPE EXISTS GET HGET HMGET HGETALL SMEMBERS LRANGE LINDEX ZRANGE ZCARD].freeze

      # Bounded per call, so a stalled server costs seconds and never hangs an
      # operator's shell. No retries: a read that failed is reported, not replayed.
      CLIENT_LIMITS = { connect_timeout: 2.0, read_timeout: 5.0, write_timeout: 5.0, reconnect_attempts: 0 }.freeze

      def initialize(config)
        opts = RedisOptions.normalize(config.redis_config).except(*RedisOptions::POOL_KEYS).merge(CLIENT_LIMITS)
        @client = (RedisOptions.sentinel?(opts) ? RedisClient.sentinel(**opts) : RedisClient.config(**opts)).new_client
      end

      def call(*command)
        @client.call(*guard(command))
      end

      def pipeline(commands)
        return [] if commands.empty?

        commands.each { |command| guard(command) }
        @client.pipelined { |pipe| commands.each { |command| pipe.call(*command) } }
      end

      # Where this reads from, for the report. Built field by field so no credential
      # can reach it.
      def target
        config = @client.config
        return { 'path' => config.path, 'db' => config.db.to_i } if config.path

        { 'host' => config.host, 'port' => config.port, 'db' => config.db.to_i }
      rescue ::StandardError => e
        { 'host' => "unknown (#{e.class})" }
      end

      def close = @client.close

      private

      def guard(command)
        raise Forbidden, "#{command.first} is not a read a preflight may send" unless ALLOWED.include?(command.first)

        command
      end
    end
  end
end
