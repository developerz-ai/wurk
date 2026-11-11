# frozen_string_literal: true

require 'rbconfig'
require_relative 'reader'
require_relative '../redis_pool'

module Wurk
  module Preflight
    # What keeps app code off Redis while `wurk boot-check` or `wurk preflight
    # --app` boots the app. Their initializers run, `configure_server` blocks
    # included, and some of those write Redis at boot (a dev-only `flushdb`, a
    # seed). Installed before the app loads, it rides every pool Wurk builds
    # (RedisPool.guard) as a redis-client middleware, so `Sidekiq.redis`,
    # `Wurk.redis` and every Wurk data view are covered whichever method or
    # pipeline sends the command. A client the app opens itself (`Redis.new`,
    # `Rails.cache`) is not Wurk's and is not covered.
    module RedisGuard
      # Not a RedisClient::Error, so no pool or caller retries it as a blip.
      class Refused < StandardError; end

      # Sent by redis-client itself while it dials; none of them changes data.
      HANDSHAKE = %w[HELLO AUTH SELECT ROLE PING].freeze
      CLIENT_HANDSHAKE = %w[SETINFO SETNAME].freeze
      LIB = ::File.expand_path('../..', __dir__)
      GEM_FRAMES = %r{/(?:redis-client|hiredis-client|connection_pool)-[^/]+/}
      STDLIB = ::RbConfig::CONFIG['rubylibdir']

      # Opens no socket at all, so no command of any kind reaches the server.
      module Closed
        def connect(_config)
          raise Refused, RedisGuard.message('opened a Redis connection', 'runs no Redis command')
        end
      end

      # Lets through the reads a preflight may send, and the handshake.
      module ReadOnly
        def call(command, _config)
          RedisGuard.check!(command)
          super
        end

        def call_pipelined(commands, _config)
          commands.each { |command| RedisGuard.check!(command) }
          super
        end
      end

      class << self
        attr_reader :label

        # `mode` is :closed or :read_only. Process-wide, as the boot it guards is.
        def install(mode, label:)
          @label = label
          RedisPool.guard = mode == :closed ? Closed : ReadOnly
        end

        def uninstall
          RedisPool.guard = nil
          @label = nil
        end

        def check!(command)
          return if allowed?(command)

          raise Refused, message("sent #{command.first.to_s.upcase}", 'sends only reads')
        end

        def allowed?(command)
          name = command.first.to_s.upcase
          return CLIENT_HANDSHAKE.include?(command[1].to_s.upcase) if name == 'CLIENT'

          Reader::ALLOWED.include?(name) || HANDSHAKE.include?(name)
        end

        def message(what, policy)
          "#{label}: #{culprit} #{what} while the app booted, and #{label} #{policy}. App code that touches Redis " \
            'at boot (a flushdb, a seed) would reach a real server here. Move it into `config.on(:startup)`, which ' \
            "only a running worker fires#{', or pass --redis to allow reads' if policy.start_with?('runs')}."
        end

        # The first frame outside Wurk, the Redis client and the pool: the app
        # file (an initializer, a gem's railtie) that asked for Redis.
        def culprit(locations = caller_locations)
          frame = locations.find { |loc| app_frame?(loc.absolute_path || loc.path) }
          frame ? "#{frame.path}:#{frame.lineno}" : 'app code'
        end

        private

        def app_frame?(path)
          return false if path.nil? || path.start_with?('<internal:', LIB, STDLIB)

          !GEM_FRAMES.match?(path)
        end
      end
    end
  end
end
