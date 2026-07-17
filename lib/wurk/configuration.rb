# frozen_string_literal: true

require 'etc'
require 'logger'
require_relative 'middleware/chain'
require_relative 'capsule'
require_relative 'context'
require_relative 'topology'

module Wurk
  # Owns runtime knobs (concurrency, queues, timeouts, lifecycle events,
  # error/death handlers) and the registry of Capsules. Single source of truth
  # for everything the swarm / managers / processors need to boot.
  #
  # Spec: docs/target/sidekiq-free.md §4 (Sidekiq::Config).
  class Configuration # rubocop:disable Metrics/ClassLength
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
        fork: [],
        quiet: [],
        shutdown: [],
        exit: [],
        heartbeat: [],
        beat: [],
        leader: []
      },
      dead_max_jobs: 10_000,
      dead_timeout_in_seconds: 180 * 24 * 60 * 60,
      reloader: proc { |&b| b.call },
      backtrace_cleaner: ->(bt) { bt },
      logged_job_attributes: %w[bid tags],
      redis_idle_timeout: nil,
      redis_error_handlers: []
    }.freeze

    # :fork fires only inside swarm children, after fork + internal AR/Redis
    # reconnect — apps reopen sockets / non-fork-safe libs there (Ent §7.4).
    LIFECYCLE_EVENTS = %i[startup fork quiet shutdown exit heartbeat beat leader].freeze
    DEFAULT_THREAD_PRIORITY = -1

    # Redis client / pool errors that the pool wrapper already retried before
    # re-raising. Logged one level up (WARN, not INFO) so a transient blip
    # surfaces in ops dashboards without drowning steady-state noise (#101).
    # RedisClient + ConnectionPool are always loaded before this file (capsule
    # → redis_pool requires both), so referencing them here is safe.
    REDIS_ERROR_CLASSES = [RedisClient::Error, ConnectionPool::TimeoutError].freeze

    # Default error handler. Wraps the report in the thread-local
    # Wurk::Context so logger formatters/JSON layouts can pick up jid/bid/tags.
    # `full_message` (with backtrace) in dev/debug, `detailed_message` in prod —
    # mirrors the Sidekiq behavior so log scrapers built for one work for both.
    #
    # Spec: docs/target/sidekiq-free.md §4.3.
    ERROR_HANDLER = lambda do |ex, ctx, cfg = Wurk.configuration|
      safe_ctx = ctx || {}
      Wurk::Context.with(safe_ctx) do
        dev = $DEBUG || ENV['WURK_DEBUG'] || cfg.logger.debug?
        msg = dev ? ex.full_message : ex.detailed_message
        level = REDIS_ERROR_CLASSES.any? { |k| ex.is_a?(k) } ? :warn : :info
        cfg.logger.public_send(level) { msg }
      end
    end

    attr_reader :capsules, :directory, :redis_config, :super_fetch_callback
    attr_accessor :thread_priority

    # Pro parity: callable that builds the statsd / dogstatsd client.
    # Invoked once per process AFTER fork; see Wurk::Metrics::Statsd.client.
    # Assignable as a Proc, lambda, or any object responding to #call:
    #
    #   config.dogstatsd = -> { Datadog::Statsd.new('host', 8125) }
    #
    # Spec: docs/target/sidekiq-pro.md §9.1.
    attr_accessor :dogstatsd

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

    # @return [Integer] threads per worker process for the default capsule
    #   (default 5). The *process* count is separate — set via `WURK_COUNT`
    #   (defaults to the CPU count). With a single capsule, total in-flight
    #   jobs = `WURK_COUNT × concurrency`; with multiple capsules see
    #   {#total_concurrency} for the cluster aggregate.
    def concurrency = default_capsule.concurrency

    # @param val [Integer] threads per worker process
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

    # Disconnect and drop every cached pool — the per-capsule mains plus
    # the config-level internal pool. Used by Wurk::Swarm so the parent
    # never leaks sockets into forks and each child can build fresh ones.
    def reset_redis_pools!
      @capsules.each_value(&:reset_redis_pools!)
      @local_redis_pool&.disconnect!
      @local_redis_pool = nil
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

    # Telemetry hook fired by RedisPool on every transient-error retry and
    # final give-up. The block receives one Hash: { error:, attempt:, retried:,
    # pool: }. Opt-in — pools stay silent until a handler is registered.
    def on_redis_error(&block)
      raise ArgumentError, 'block required for on_redis_error' unless block

      @options[:redis_error_handlers] << block
    end

    def redis_error_handlers
      @options[:redis_error_handlers]
    end

    def average_scheduled_poll_interval=(interval)
      @options[:average_scheduled_poll_interval] = interval
    end

    # Reliable-fetch empty-poll backoff: the BLMOVE block timeout (seconds)
    # used when every served queue is empty. Pro super_fetch §3.3's
    # `fetch_poll_interval` knob. Unset (nil) → the fetcher's default
    # (Wurk::Fetcher::Reliable::TIMEOUT, 2s). Also readable as
    # `config[:fetch_poll_interval]`.
    def fetch_poll_interval=(seconds)
      @options[:fetch_poll_interval] = seconds
    end

    def fetch_poll_interval
      @options[:fetch_poll_interval]
    end

    # --- Reliability (Sidekiq Pro drop-in no-ops) ------------------------

    # Sidekiq Pro's opt-in toggles for reliable fetch and the reliable
    # scheduler. Both are already the default in Wurk — the fetcher is always
    # the reliable BLMOVE fetcher with orphan reclamation, and the scheduler is
    # always atomic Lua — so the toggle itself is a no-op. They exist only so a
    # Pro initializer drops in unchanged instead of raising NoMethodError.
    #
    # The optional block is Pro's recovery callback: `|jobstr, pill|`, fired
    # once per orphan recovery (`pill` nil) and once on a poison kill (`pill`
    # responds to .jid/.klass/.count/.queue). The reaper drives it via
    # Wurk::Middleware::PoisonPill.track!. Spec: docs/target/sidekiq-pro.md §3.1.
    def super_fetch!(*, &block)
      @super_fetch_callback = block if block
      nil
    end

    # Pro reliable scheduler (§4): promote due jobs from retry/schedule onto
    # their target queue in a single atomic Lua (ZRANGEBYSCORE+ZREM+LPUSH),
    # closing the pop→push job-loss window of the default poller. Swaps the
    # pluggable `scheduled_enq` for the atomic promoter; idempotent.
    def reliable_scheduler!(*)
      self[:scheduled_enq] = Wurk::Scheduled::ReliableEnq
      nil
    end

    # --- Periodic (Cron) registration ------------------------------------

    # Yields a Wurk::Cron::Manager so the host app can register periodic
    # jobs at boot. Manager state is shared per-process so multiple
    # `config.periodic` blocks accumulate (matches Sidekiq Ent §2.1). This is
    # the native replacement for the `sidekiq-cron` gem.
    #
    # @example Register cron jobs at boot
    #   Wurk.configure_server do |config|
    #     config.periodic do |mgr|
    #       mgr.register("*/5 * * * *", ReportJob)
    #       mgr.register("0 0 * * *", NightlyJob, tz: "UTC")
    #     end
    #   end
    # @yieldparam mgr [Wurk::Cron::Manager] call `mgr.register(cron, JobClass, **opts)`
    # @return [Wurk::Cron::Manager]
    #
    # Spec: docs/target/sidekiq-ent.md §2.
    def periodic
      require_relative 'cron'
      @periodic_manager ||= Wurk::Cron::Manager.new(self)
      yield @periodic_manager if block_given?
      @periodic_manager
    end

    # --- Historical metrics snapshotter (Ent §5) -------------------------

    HISTORY_DEFAULT_INTERVAL = 30

    # Enables the Ent Historical Metrics snapshotter: every `seconds` the
    # cluster leader emits a statsd-shaped snapshot to the configured
    # `dogstatsd` client. With no block the default §5.2 gauge set is
    # published; a block receives the dogstatsd client `s` and collects
    # custom metrics instead. The Launcher starts the snapshotter only when
    # this has been called.
    #
    # Spec: docs/target/sidekiq-ent.md §5.1.
    def retain_history(seconds = HISTORY_DEFAULT_INTERVAL, &block)
      guard_frozen!
      interval = Float(seconds)
      raise ArgumentError, 'retain_history interval must be > 0' unless interval.positive?

      @options[:history_interval] = interval
      @options[:history_collector] = block
      nil
    end

    def history_enabled? = @options.key?(:history_interval)
    def history_interval = @options.fetch(:history_interval, HISTORY_DEFAULT_INTERVAL)
    def history_collector = @options[:history_collector]

    # --- Web dashboard ----------------------------------------------------

    # Web UI configuration: the authorization hook and read-only mode. Returns
    # the process-wide `Wurk::Web.config` singleton so `config.web.read_only =
    # true` and the engine middleware share one source of truth. Lazy-requires
    # the web layer to keep standalone boot lean.
    #
    # Spec: docs/target/sidekiq-ent.md §9.2.
    def web
      require_relative 'web/config'
      Wurk::Web.config
    end

    # --- K8s liveness/readiness probes -----------------------------------

    # Opt-in thin HTTP listener inside the worker process for k8s probes.
    # When called, the Launcher will start a TCP server on `port` bound to
    # `bind` exposing `GET /live` (200 while not stopping) and `GET /ready`
    # (200 only when Redis is reachable AND heartbeat fired within
    # `ready_window` seconds).
    #
    # Off by default — call this in a `configure_server` block to enable.
    # Spec: docs/target/sidekiq-ent.md §7.1.2.
    def health_check(port:, bind: '0.0.0.0', ready_window: 30)
      guard_frozen!
      p = Integer(port)
      rw = Integer(ready_window)
      raise ArgumentError, 'port must be between 0 and 65535' unless (0..65535).cover?(p)
      raise ArgumentError, 'ready_window must be > 0' unless rw.positive?

      b = bind.to_s
      raise ArgumentError, 'bind must be a non-empty string' if b.empty?

      @options[:health_check_options] = { port: p, bind: b, ready_window: rw }
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

    # Worker topology for the swarm. When the host hasn't declared one (the
    # railtie path), default to a single flat fork running the default
    # capsule's queues + concurrency. Assign a custom Wurk::Topology (via
    # `topology=`) for specialized slots.
    def topology
      @topology ||= default_topology
    end

    def topology=(value)
      guard_frozen!
      @topology = value
    end

    # Memory-based child recycling (Sidekiq Ent §7.5): the swarm parent TERMs
    # (and respawns) any child whose RSS exceeds this many MB. Set in code or
    # via SIDEKIQ_MAXMEM_MB (WURK_MAXMEM_MB is the native alias); an explicit
    # value wins over the env. nil/0 disables recycling (the default).
    def memory_limit_mb
      @memory_limit_mb || env_memory_limit_mb
    end

    def memory_limit_mb=(value)
      guard_frozen!
      @memory_limit_mb = value.nil? ? nil : Integer(value)
    end

    # Threshold in KB, the unit the swarm compares against /proc/<pid>/statm
    # (pages × 4KB). nil when recycling is disabled.
    def memory_limit_kb
      mb = memory_limit_mb
      mb&.positive? ? mb * 1024 : nil
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

    # One flat fork running the default capsule's queues + concurrency. The
    # railtie boots this when a Rails host mounts the engine without declaring
    # a topology. queue_specs (not queues) so weights survive the round-trip.
    def default_topology
      cap = default_capsule
      Wurk::Topology.flat(count: default_child_count, queues: cap.queue_specs, concurrency: cap.concurrency)
    end

    # Number of swarm children when the host hasn't declared a topology
    # (Sidekiq Ent §7.2). Defaults to the CPU count. A whole number is an
    # absolute count; a fractional value is a CPU multiplier (e.g. `0.5` → half
    # the cores, rounded), supported since Sidekiq 8.0.2. WURK_COUNT is the
    # native name, SIDEKIQ_COUNT the drop-in alias. Unparseable input falls back
    # to the CPU count; the result is floored at 1 so the swarm always forks.
    def default_child_count
      raw = ENV['WURK_COUNT'] || ENV['SIDEKIQ_COUNT']
      return Etc.nprocessors if raw.nil? || raw.strip.empty?

      value = Float(raw)
      count = (value % 1).zero? ? value.to_i : (value * Etc.nprocessors).round
      [count, 1].max
    rescue ArgumentError, TypeError
      Etc.nprocessors
    end

    # SIDEKIQ_MAXMEM_MB is the drop-in name; WURK_MAXMEM_MB the native alias.
    # Unparseable / empty input disables recycling rather than raising at boot.
    def env_memory_limit_mb
      raw = ENV['WURK_MAXMEM_MB'] || ENV['SIDEKIQ_MAXMEM_MB']
      return nil if raw.nil? || raw.strip.empty?

      Integer(raw)
    rescue ArgumentError, TypeError
      nil
    end

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

    # `size`/`name` are pool-structural (the caller owns them); every other
    # key the host set via `config.redis = {...}` — url, the split timeouts,
    # reconnect_attempts, driver, … — flows through to RedisPool verbatim.
    # Every pool built here is wired to the redis-error telemetry dispatcher.
    def build_redis_pool(size:, name:)
      RedisPool.new(size: size, name: name, on_error: method(:dispatch_redis_error),
                    **@redis_config.except(:size, :name))
    end

    # Fan a RedisPool retry/give-up event out to the registered handlers. A
    # raising handler is logged and skipped so one bad hook can't break the
    # pool's retry path (mirrors #handle_exception).
    def dispatch_redis_error(info)
      redis_error_handlers.each do |handler|
        handler.call(info)
      rescue StandardError => e
        logger.error("redis_error_handler raised: #{e.class}: #{e.message}")
      end
    end
  end
end
