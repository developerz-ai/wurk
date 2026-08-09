# frozen_string_literal: true

require 'etc'
require 'logger'
require_relative 'middleware/chain'
require_relative 'capsule'
require_relative 'pool_checkout'
require_relative 'context'
require_relative 'topology'
require_relative 'redis_options'
require_relative 'keys'

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
      redis_error_handlers: [],
      # Wurk extras, appended after the mirrored keys so the Sidekiq prefix
      # above stays byte-for-byte what a gem reading @options expects.
      #
      # Lifetime of a `status:<jid>` row (Wurk::Status), re-stamped on every
      # write, and the separate lifetime a `complete` row gets once the job
      # succeeded. Retention is off by default — nil means a finished job's
      # row expires on the same clock as a running one. Set it to seconds to
      # keep succeeded jobs around longer than they ran, or to 0 for Sidekiq's
      # own behavior, where a job that succeeds leaves nothing behind.
      status_ttl: Keys::STATUS_TTL,
      status_retention: nil,
      # Distributed tracing (Wurk::Telemetry). Seeded here, not written on
      # demand, so the read side answers on a config that `freeze!` has already
      # closed — and so a gem inspecting @options sees the same key set whether
      # or not the host traces. Flipping it is only half the gate; the
      # opentelemetry-api gem has to be present too (Wurk::Telemetry.enabled?).
      telemetry: false,
      # Bearer tokens for the machine-facing HTTP API (Wurk::API), as
      # `token => [scopes]`. Empty means the API does not exist: the engine
      # skips the mount and a directly mounted app answers 404, so a host that
      # never registers a token carries no new HTTP surface at all. Seeded here
      # rather than written on demand so the read side answers on a config that
      # `freeze!` has already closed.
      api_tokens: {},
      # Boundary caps for the HTTP API's produce plane. A body larger than
      # `api_max_body_bytes` is refused before it is parsed; a job whose args
      # serialize larger than `api_max_args_bytes` before it is pushed — the
      # second is the one that bounds what a bulk request lands in Redis, since
      # one request becomes many payloads. `api_idempotency_ttl` is how long an
      # `Idempotency-Key` is remembered: a replay window for a producer
      # retrying a lost response, not an audit log.
      api_max_body_bytes: 1_048_576,
      api_max_args_bytes: 65_536,
      api_idempotency_ttl: 3_600,
      # Allow-list of classes the HTTP API may enqueue. nil (the default) means
      # only an `admin` token may enqueue at all — see #api_enqueue_classes=.
      api_enqueue_classes: nil,
      # Three-state on purpose — see #api_read_only=. nil is "inherit", which
      # only mount mode 1 has anything to inherit from.
      api_read_only: nil,
      # Per-token request ceiling. nil is off: the API adds no Redis work to a
      # request until a host asks for a limit, and no number picked here would
      # be right for both a cron relay and a fan-out producer.
      api_rate_limit: nil,
      api_rate_limit_interval: :minute
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
    attr_reader :dogstatsd

    # Assignment drops Statsd's resolved-client memo. That memo caches the
    # "nothing configured" answer too (so the no-client emit path allocates
    # nothing), which means a builder wired up after the first emit would
    # otherwise never be picked up.
    def dogstatsd=(builder)
      @dogstatsd = builder
      Wurk::Metrics::Statsd.reset!
    end

    def initialize(options = {})
      @options = deep_dup_defaults.merge(options)
      @options[:error_handlers] << ERROR_HANDLER if @options[:error_handlers].empty?
      @capsules = {}
      @directory = {}
      @client_chain = Middleware::Chain.new
      @server_chain = Middleware::Chain.new
      @redis_config = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0') }
      @web_redis_pool = nil
      @logger = nil
      @thread_priority = DEFAULT_THREAD_PRIORITY
      @telemetry_installed = false
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

    # Validated here, in the process running the initializer, rather than later
    # in whichever process first builds a pool. The swarm's children are the ones
    # that construct pools, so a bad key used to kill every child on boot while
    # the parent stayed up and healthy — Running pod, passing probe, zero jobs
    # processed (#283).
    def redis=(hash)
      guard_frozen!
      RedisOptions.validate!(hash)
      @redis_config = @redis_config.merge(hash.transform_keys(&:to_sym))
    end

    def redis_pool
      default_capsule.redis_pool
    end

    # Disconnect and drop every capsule's cached pools (main + fetch) plus the
    # web pool. Used by Wurk::Swarm so the parent never leaks sockets into forks
    # and each child can build fresh ones.
    def reset_redis_pools!
      @capsules.each_value(&:reset_redis_pools!)
      @web_redis_pool&.disconnect!
      @web_redis_pool = nil
    end

    def new_redis_pool(size, name = 'custom')
      build_redis_pool(size: size, name: name)
    end

    def redis(idempotent: false, &)
      PoolCheckout.trusted(redis_pool, idempotent, &)
    end

    # --- Web dashboard Redis pool ----------------------------------------

    # Default connection count for the dedicated web pool (#web_redis_pool).
    WEB_POOL_DEFAULT_SIZE = 5

    # Deliberately short checkout wait for the web pool: a saturated dashboard
    # should fail fast rather than tie up a web-server thread queuing for a slot.
    WEB_POOL_TIMEOUT = 1.0

    # Connections in the dedicated web pool. `config.web_pool_size = N` overrides
    # the default; independent of `config.redis[:size]`, which sizes the worker
    # capsules — the two pools are deliberately disjoint (#101).
    def web_pool_size
      @options[:web_pool_size] || WEB_POOL_DEFAULT_SIZE
    end

    def web_pool_size=(size)
      guard_frozen!
      @options[:web_pool_size] = Integer(size)
    end

    # Dedicated Redis pool for the dashboard / JSON API / SSE, disjoint from
    # every worker capsule's pool. Dashboard load — an API burst, a long-lived
    # SSE stream — can no longer drain the connections a co-located (embedded)
    # worker needs to fetch and heartbeat, and vice versa: the #101 `0/N`
    # pool-exhaustion incident. Lazy, so a headless worker that never serves the
    # dashboard builds nothing; web entry points route `Wurk.redis` here through
    # Wurk::Web::PoolScope. The Configuration instance is never frozen (only its
    # @options/@capsules are), so this `||=` is safe to fire post-boot.
    def web_redis_pool
      @web_redis_pool ||= build_redis_pool(size: web_pool_size, name: 'web', pool_timeout: WEB_POOL_TIMEOUT)
    end

    # --- Service locator (extension registry) ----------------------------

    def register(name, instance)
      guard_frozen!
      @directory[name] = instance
    end

    # Memoizes on a miss, and the first miss can land long after boot (an
    # extension resolved on its first tick), which is why `freeze!` leaves
    # `@directory` writable: frozen, that lookup raised FrozenError instead of
    # building the default. `register` — the host-facing half — still refuses
    # writes past the freeze, so the closed surface is unchanged.
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

    # --- Reliability (Sidekiq Pro drop-in toggles) -----------------------

    # Sidekiq Pro's opt-in toggle for reliable fetch. Already the default in
    # Wurk — the fetcher is always the reliable BLMOVE fetcher with orphan
    # reclamation — so the toggle is a no-op beyond capturing the recovery
    # callback. It exists so a Pro initializer drops in unchanged instead of
    # raising NoMethodError.
    #
    # NOTE: `reliable_scheduler!` below is NOT a no-op. The default
    # `scheduled_enq` pops then pushes and has a job-loss window
    # (Wurk::Scheduled::Enq); only the toggle swaps in the atomic promoter.
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

    # --- Distributed tracing (OpenTelemetry) ------------------------------

    # @return [Boolean] whether the host asked for tracing. Half the gate;
    #   {Wurk::Telemetry.enabled?} is the whole one.
    def telemetry? = @options[:telemetry] == true

    # Opt into Wurk::Telemetry — a producer span carrying W3C trace context on
    # the job hash at enqueue, a linked consumer span on execute:
    #
    #   Wurk.configure_server { |config| config.telemetry = true }
    #
    # Loading `wurk/telemetry` is deferred to this call, which is the only
    # reason `require "wurk"` can leave `opentelemetry-api` untouched in an app
    # that doesn't trace.
    #
    # Warns when the host opted in but the gem is missing: tracing then stays
    # off, and a silent no-op is indistinguishable from a broken exporter.
    def telemetry=(enabled)
      guard_frozen!
      @options[:telemetry] = enabled ? true : false
      # Turning tracing back off still has to unregister, but must not *load*
      # the module to do it — that require is the whole cost this flag gates,
      # and a config that never opted in has nothing registered to undo. Tracked
      # per instance rather than off `defined?(Wurk::Telemetry)`: whether some
      # *other* config loaded the module says nothing about this one's chain.
      return if !@options[:telemetry] && !@telemetry_installed

      require_relative 'telemetry'
      @telemetry_installed = true
      Wurk::Telemetry.install!(self)
      return if !@options[:telemetry] || Wurk::Telemetry.available?

      logger.warn { 'config.telemetry = true but opentelemetry-api is not installed; tracing stays off' }
    end

    # --- Machine-facing HTTP API (Wurk::API) ------------------------------

    # Registers a bearer token for the HTTP API and the scopes it grants —
    # any of `:enqueue`, `:read`, `:admin` (which grants the other two):
    #
    #   # config/initializers/wurk.rb
    #   Wurk.configuration.api_token ENV.fetch('WURK_API_TOKEN'), scopes: %i[enqueue read]
    #
    # Registered unconditionally, not inside `configure_server`/`configure_client`
    # — the process that serves the API has to be the one holding the credential,
    # and neither block runs in every such process. A Puma-cluster web process
    # never enters server mode (Wurk::RailsBoot refuses to fork a swarm from
    # one), so a token registered in `configure_server` would be absent from the
    # exact process serving the engine-nested mount.
    #
    # Registering the first token is what brings the API into existence; with
    # none the app is never mounted. Re-registering a token replaces its
    # scopes. Loading `wurk/api/auth` is deferred to this call so a host that
    # serves no HTTP API never pays for openssl/digest in every swarm child.
    def api_token(token, scopes:)
      guard_frozen!
      require_relative 'api/auth'
      value, granted = Wurk::API::Auth.credential!(token, scopes)
      @options[:api_tokens][value] = granted
      nil
    end

    # @return [Hash{String => Array<Symbol>}] registered tokens and their scopes
    def api_tokens = @options[:api_tokens]

    # @return [Boolean] whether the HTTP API exists at all. The engine's mount
    #   is conditional on this.
    def api_enabled? = !@options[:api_tokens].empty?

    # @return [Integer] largest request body the produce plane will read.
    def api_max_body_bytes = @options[:api_max_body_bytes]

    def api_max_body_bytes=(bytes)
      @options[:api_max_body_bytes] = api_limit!(:api_max_body_bytes, bytes)
    end

    # @return [Integer] largest `args` any single job may serialize to.
    def api_max_args_bytes = @options[:api_max_args_bytes]

    def api_max_args_bytes=(bytes)
      @options[:api_max_args_bytes] = api_limit!(:api_max_args_bytes, bytes)
    end

    # @return [Integer] seconds an `Idempotency-Key` stays replayable.
    def api_idempotency_ttl = @options[:api_idempotency_ttl]

    def api_idempotency_ttl=(seconds)
      @options[:api_idempotency_ttl] = api_limit!(:api_idempotency_ttl, seconds)
    end

    # @return [Array<String>, :any, nil] classes the HTTP API may enqueue.
    def api_enqueue_classes = @options[:api_enqueue_classes]

    # The allow-list `JobUtil::TRANSIENT_ATTRIBUTES` deliberately is not — that
    # is a strip-list, right for a producer already running your code:
    #
    #   config.api_enqueue_classes = %w[Billing::Charge ReportJob]
    #
    # Unset, only an `admin` token may enqueue at all. `class` is a code
    # selector — a producer token that can name any constant in the host is
    # choosing which of its jobs to run — so an `enqueue`-scoped credential has
    # to be told exactly what it is for. Once a list exists it binds every
    # token, `admin` included: a host that writes one means it.
    #
    # `:any` turns the check off, which is what an enqueue-scoped relay that
    # legitimately pushes arbitrary classes needs — the alternative is handing
    # it `admin` and the destructive routes that come with it.
    def api_enqueue_classes=(classes)
      guard_frozen!
      require_relative 'api/validation'
      @options[:api_enqueue_classes] = Wurk::API::Validation.enqueueable_classes!(classes)
    end

    # @return [Boolean, nil] true/false when the host said so, nil to inherit.
    def api_read_only = @options[:api_read_only]

    # Freezes the API's writes — enqueue included, not only the destructive
    # `admin` routes. Same rule as the dashboard's `Wurk::Web.config.read_only`
    # and deliberately the same sentence: a read-only deployment answers reads.
    # Carving enqueue out would mean a viewer-only deploy could still be made
    # to run arbitrary work, and would leave an operator holding two different
    # definitions of the same word.
    #
    # Three states, because the two planes are not always one deployment:
    #
    #   nil (default)  inherit. Mounted inside the engine, the API is part of
    #                  the dashboard's deployment and `WURK_WEB_READ_ONLY=1`
    #                  freezes both. Mounted on its own path or run standalone
    #                  there is nothing to inherit from and this means off.
    #   true           frozen wherever it is mounted. `WURK_API_READ_ONLY=1`
    #                  sets it, which is the only door mode 3 has.
    #   false          live even inside a read-only dashboard — the host that
    #                  wants a viewer-only UI and a working producer on the
    #                  same mount, said out loud.
    def api_read_only=(value)
      guard_frozen!
      @options[:api_read_only] = value.nil? ? nil : truthy_setting?(value)
    end

    # @return [Boolean] the resolved verdict for a mount with nothing to
    #   inherit; App layers mode 1's inherited flag over it.
    def api_read_only?
      value = @options[:api_read_only]
      value.nil? ? ENV['WURK_API_READ_ONLY'] == '1' : value
    end

    # @return [Integer, nil] requests one token may make per interval.
    def api_rate_limit = @options[:api_rate_limit]

    # Requests per `api_rate_limit_interval`, per token, across the fleet —
    # enforced by a `Wurk::Limiter` sliding window rather than a second
    # limiter, so an API ceiling shows up on the Limiters page beside every
    # other one and resets on the same Redis clock. nil turns it off.
    def api_rate_limit=(count)
      guard_frozen!
      @options[:api_rate_limit] = count.nil? ? nil : api_limit!(:api_rate_limit, count)
    end

    # @return [Symbol, Integer] the window the limit is counted over.
    def api_rate_limit_interval = @options[:api_rate_limit_interval]

    # `:second :minute :hour :day` or a raw Integer of seconds — whatever
    # `Limiter.window` accepts, validated here so a typo raises in the
    # initializer that wrote it rather than on the first throttled request.
    def api_rate_limit_interval=(interval)
      guard_frozen!
      Wurk::Limiter.interval_seconds(interval, allow_integer: true)
      @options[:api_rate_limit_interval] = interval
    end

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
      raise ArgumentError, 'port must be between 0 and 65535' unless (0..65_535).cover?(p)
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

    # The pre-fork half of `freeze!`, and the only half a forking parent can
    # run: capsules stay writable until each child has applied its slot
    # (ChildBoot#apply_slot_to_config) and opened its own Redis pools. What is
    # left is slot-independent — the options Hash and every capsule's middleware
    # chains — so the swarm parent settles it once and every child inherits the
    # result copy-on-write instead of allocating and dirtying its own copy.
    # Freezing the options here also makes a post-fork option write raise in the
    # child that wrote it, rather than silently diverging from its siblings.
    #
    # `@directory` is deliberately left out — see #lookup.
    def prepare_for_fork!
      # The capsule every swarm child configures (ChildBoot reaches for it by
      # name), and the one a client-only config builds on its first enqueue.
      # Materialized here so its chains are shared rather than rebuilt N times
      # — and so `freeze!` can't close `@capsules` around a name that is only
      # ever resolved later, which turned that first resolution into a
      # FrozenError on the frozen Hash.
      default_capsule
      @capsules.each_value(&:prepare_shared!)
      @options.freeze
      @frozen = true
      self
    end

    # Guarded on the capsule table, not `@frozen`: a swarm child reaches this
    # with `prepare_for_fork!` already run in its parent, so `@frozen` is true
    # while the capsules it has just configured are still open.
    def freeze!
      return self if @capsules.frozen?

      prepare_for_fork!
      @capsules.each_value(&:freeze)
      @capsules.freeze
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
      raw = ENV['WURK_COUNT'] || ENV.fetch('SIDEKIQ_COUNT', nil)
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
      raw = ENV['WURK_MAXMEM_MB'] || ENV.fetch('SIDEKIQ_MAXMEM_MB', nil)
      return nil if raw.nil? || raw.strip.empty?

      Integer(raw)
    rescue ArgumentError, TypeError
      nil
    end

    def guard_frozen!
      raise FrozenError, 'Wurk::Configuration is frozen' if @frozen
    end

    # `config.api_read_only = ENV['SOMETHING']` is the shape a host reaches for,
    # and `!!'false'` is true. Borrow the dashboard's list of strings that mean
    # off rather than growing a second one that could disagree with it about the
    # same env var.
    def truthy_setting?(value)
      return !!value unless value.is_a?(String)

      require_relative 'web/config'
      !Wurk::Web::Config::FALSEY_STRINGS.include?(value.strip.downcase)
    end

    # Boundary caps are refused where they are written, not where they are
    # read: a cap that silently coerced to 0 is a cap that isn't one, and the
    # request path is the wrong place to discover that.
    def api_limit!(name, value)
      guard_frozen!
      size = Integer(value, exception: false)
      raise ArgumentError, "#{name} must be a positive Integer" unless size&.positive?

      size
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
    # `overrides` win over the host config (the web pool pins its own
    # pool_timeout this way). Every pool built here is wired to the redis-error
    # telemetry dispatcher.
    def build_redis_pool(size:, name:, **overrides)
      RedisPool.new(size: size, name: name, on_error: method(:dispatch_redis_error),
                    **@redis_config.except(:size, :name), **overrides)
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
