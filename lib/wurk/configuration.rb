# frozen_string_literal: true

require 'logger'
require_relative 'middleware/chain'
require_relative 'capsule'
require_relative 'context'

module Wurk
  # Owns runtime knobs (concurrency, queues, timeouts, lifecycle events,
  # error/death handlers) and the registry of Capsules. Single source of truth
  # for everything the swarm / managers / processors need to boot.
  #
  # Spec: docs/target/sidekiq-free.md §4 (Sidekiq::Config).
  class Configuration
    # Mirrors Sidekiq::Config::DEFAULTS. Order and keys are part of the
    # drop-in contract — third-party gems read @options via [] / fetch / dig.
    DEFAULTS = {
      labels: Set.new,
      require: '.',
      environment: nil,
      concurrency: 5,
      timeout: 25,
      poll_interval_average: nil,
      average_scheduled_poll_interval: 5,
      on_complex_arguments: :raise,
      max_iteration_runtime: nil,
      error_handlers: [],
      death_handlers: [],
      lifecycle_events: {
        startup: [],
        quiet: [],
        shutdown: [],
        exit: [],
        heartbeat: [],
        beat: []
      },
      dead_max_jobs: 10_000,
      dead_timeout_in_seconds: 180 * 24 * 60 * 60,
      reloader: proc { |&b| b.call },
      backtrace_cleaner: ->(bt) { bt },
      logged_job_attributes: %w[bid tags],
      redis_idle_timeout: nil
    }.freeze

    LIFECYCLE_EVENTS = %i[startup quiet shutdown exit heartbeat beat].freeze
    DEFAULT_THREAD_PRIORITY = -1

    # Default error handler. Wraps the report in the thread-local
    # Wurk::Context so logger formatters/JSON layouts can pick up jid/bid/tags.
    # `full_message` (with backtrace) in dev/debug, `detailed_message` in prod —
    # mirrors the Sidekiq behavior so log scrapers built for one work for both.
    #
    # Spec: docs/target/sidekiq-free.md §4.3.
    ERROR_HANDLER = lambda do |ex, ctx, cfg = Wurk.configuration|
      Wurk::Context.with(ctx) do
        dev = $DEBUG || ENV['WURK_DEBUG'] || cfg.logger.debug?
        msg = dev ? ex.full_message : ex.detailed_message
        cfg.logger.info { msg }
      end
    end

    attr_reader :capsules, :directory, :redis_config
    attr_accessor :thread_priority

    def initialize(options = {})
      @options = deep_dup_defaults.merge(options)
      @options[:error_handlers] << ERROR_HANDLER if @options[:error_handlers].empty?
      @capsules = {}
      @directory = {}
      @client_chain = Middleware::Chain.new
      @server_chain = Middleware::Chain.new
      @redis_config = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0') }
      @logger = nil
      @thread_priority = DEFAULT_THREAD_PRIORITY
      @frozen = false
    end

    # --- Hash-like options access -----------------------------------------

    def [](key) = @options.[](key)

    def []=(key, val)
      guard_frozen!
      @options[key] = val
    end

    def fetch(*, &) = @options.fetch(*, &)
    def key?(key) = @options.key?(key)
    alias has_key? key?
    def merge!(other)
      guard_frozen!
      @options.merge!(other)
    end

    def dig(*keys) = @options.dig(*keys)

    # --- Default capsule shortcuts ---------------------------------------

    def concurrency = default_capsule.concurrency

    def concurrency=(val)
      default_capsule.concurrency = val
    end

    def queues = default_capsule.queues

    def queues=(val)
      default_capsule.queues = val
    end

    def total_concurrency
      @capsules.each_value.sum(&:concurrency)
    end

    def default_capsule(&)
      capsule('default', &)
    end

    def capsule(name)
      name = name.to_s
      cap = @capsules[name] ||= Capsule.new(name, self)
      yield cap if block_given?
      cap
    end

    # --- Middleware -------------------------------------------------------

    def client_middleware
      yield @client_chain if block_given?
      @client_chain
    end

    def server_middleware
      yield @server_chain if block_given?
      @server_chain
    end

    # --- Redis ------------------------------------------------------------

    def redis=(hash)
      guard_frozen!
      @redis_config = @redis_config.merge(hash.transform_keys(&:to_sym))
    end

    def redis_pool
      default_capsule.redis_pool
    end

    def local_redis_pool
      @local_redis_pool ||= build_redis_pool(size: 10, name: 'internal')
    end

    def new_redis_pool(size, name = 'custom')
      build_redis_pool(size: size, name: name)
    end

    def redis(&)
      redis_pool.with(&)
    end

    # --- Service locator (extension registry) ----------------------------

    def register(name, instance)
      guard_frozen!
      @directory[name] = instance
    end

    def lookup(name, default_class = nil)
      @directory[name] ||= default_class&.new
    end

    # --- Handlers ---------------------------------------------------------

    def error_handlers
      @options[:error_handlers]
    end

    def death_handlers
      @options[:death_handlers]
    end

    def average_scheduled_poll_interval=(interval)
      @options[:average_scheduled_poll_interval] = interval
    end

    # --- Lifecycle hooks --------------------------------------------------

    def on(event, &block)
      raise ArgumentError, "block required for on(#{event.inspect})" unless block
      unless LIFECYCLE_EVENTS.include?(event)
        raise ArgumentError, "invalid event #{event.inspect}, must be one of #{LIFECYCLE_EVENTS.inspect}"
      end

      @options[:lifecycle_events][event] << block
    end

    # --- Logger -----------------------------------------------------------

    def logger
      @logger ||= default_logger
    end

    attr_writer :logger

    def handle_exception(ex, ctx = {})
      if error_handlers.empty?
        logger.error("#{ctx} #{ex.class}: #{ex.message}")
      else
        error_handlers.each do |handler|
          handler.call(ex, ctx, self)
        rescue StandardError => e
          logger.error("error_handler raised: #{e.class}: #{e.message}")
        end
      end
    end

    # --- Configure blocks (Sidekiq.configure_server / _client) -----------

    def configure_server(&block)
      yield self if block && server?
    end

    def configure_client(&block)
      yield self if block && !server?
    end

    def server?
      @options[:server] == true
    end

    def freeze!
      return self if @frozen

      @capsules.each_value(&:freeze)
      @capsules.freeze
      @options.freeze
      @directory.freeze
      @frozen = true
      self
    end

    def frozen?
      @frozen
    end

    def inspect
      "#<#{self.class} capsules=#{@capsules.keys} concurrency=#{total_concurrency}>"
    end

    private

    def guard_frozen!
      raise FrozenError, 'Wurk::Configuration is frozen' if @frozen
    end

    def deep_dup_defaults
      DEFAULTS.each_with_object({}) do |(k, v), h|
        h[k] = case v
               when Hash then v.transform_values { |inner| inner.respond_to?(:dup) ? inner.dup : inner }
               when Array, Set then v.dup
               else v
               end
      end
    end

    def default_logger
      logger = Wurk::Logger.new($stdout)
      logger.level = ::Logger::INFO
      logger
    end

    def build_redis_pool(size:, name:)
      RedisPool.new(
        size: size,
        url: @redis_config[:url] || RedisPool::DEFAULT_URL,
        timeout: @redis_config[:timeout] || RedisPool::DEFAULT_TIMEOUT,
        name: name
      )
    end
  end
end
