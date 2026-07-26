# frozen_string_literal: true

require 'redis-client'
require 'connection_pool'
require_relative 'redis_client_adapter'
require_relative 'redis_options'

module Wurk
  # Per-process pool over redis-client + connection_pool. Never share a socket
  # across forks: the parent closes the pool before fork, each child opens a
  # fresh one (see docs/idea/03-process-model.md, steps 3 and 5).
  #
  # #with absorbs transient Redis failures (production incident #101):
  #   * READONLY / NOREPLICAS / UNBLOCKED — a failover happened; close and retry
  #     once immediately so redis-client redials the new primary (spec §26).
  #   * ConnectionError (incl. CannotConnect / Read- / WriteTimeout) — a blip;
  #     close and retry with exponential backoff up to CONN_MAX_ATTEMPTS, then
  #     raise. At-least-once tolerates the rare duplicate and JobRetry re-runs
  #     the job anyway, so retrying at the pool layer is strictly better.
  #   * ConnectionPool::TimeoutError — checkout starved; retry once after a
  #     short jittered pause, then raise (sizing is the fix, not queuing).
  # Every retry and final give-up is reported through the injected `on_error`
  # telemetry hook (Wurk::Configuration#on_redis_error).
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

    # The floor every pool starts from; any key the host passed wins over it.
    DEFAULT_CLIENT_CONFIG = {
      url: DEFAULT_URL,
      connect_timeout: DEFAULT_CONNECT_TIMEOUT,
      read_timeout: DEFAULT_READ_TIMEOUT,
      write_timeout: DEFAULT_WRITE_TIMEOUT,
      reconnect_attempts: DEFAULT_RECONNECT_ATTEMPTS
    }.freeze

    # Server-side messages where the connection is closed and the block retried
    # exactly once. READONLY is itself a RedisClient::ConnectionError subclass,
    # so this message match must be tested BEFORE the generic ConnectionError
    # backoff below (otherwise a failover would sleep instead of redialing).
    RETRYABLE_MSG = /\A(READONLY|NOREPLICAS|UNBLOCKED)/

    # ConnectionError backoff: CONN_MAX_ATTEMPTS total tries, sleeping
    # (BASE * 2**attempt) + rand*JITTER before each retry. The 1.0s + 2.0s pair
    # rides out a sub-4s blip; the jitter de-syncs a fleet reconnecting at once.
    CONN_MAX_ATTEMPTS   = 3
    CONN_BACKOFF_BASE   = 0.5
    CONN_BACKOFF_JITTER = 0.25

    # Checkout-timeout retry: one retry after a jittered pause in
    # [POOL_RETRY_MIN, POOL_RETRY_MIN + POOL_RETRY_SPREAD). No loop — sustained
    # checkout starvation is a sizing bug, not something to queue behind.
    POOL_RETRY_MIN    = 0.1
    POOL_RETRY_SPREAD = 0.2

    attr_reader :size, :url, :name, :pool_timeout, :client_config

    # Takes the standard Sidekiq `config.redis` hash: `pool_timeout` tunes the
    # ConnectionPool checkout; `connect_timeout`/`read_timeout`/`write_timeout`/
    # `reconnect_attempts` plus any other redis-client key (driver, ssl_params,
    # sentinels, …) reach the client. Sidekiq-only spellings (`network_timeout`,
    # `master_name`, `logger`, …) are translated or dropped by {RedisOptions};
    # a key redis-client would reject raises there with the key named.
    # `on_error` is an optional callable fired per retry / final give-up with
    # { error:, attempt:, retried:, pool: }.
    def initialize(size:, name: DEFAULT_NAME, on_error: nil, **options)
      @size          = size
      @name          = name
      @on_error      = on_error
      @pool_timeout  = options.fetch(:pool_timeout, DEFAULT_POOL_TIMEOUT)
      @client_config = build_client_config(options)
      @url           = @client_config[:url]
      @pool          = ConnectionPool.new(size: size, timeout: @pool_timeout) { build_client }
    end

    # Checkout a connection and run the block. ConnectionPool::TimeoutError is
    # raised by @pool.with *before* the block runs, so it is caught out here
    # (the in-block #run rescue never sees it) — one retry, then raise.
    def with(&block)
      checkout_retried = false
      begin
        @pool.with { |conn| run(conn, &block) }
      rescue ConnectionPool::TimeoutError => e
        if checkout_retried
          notify_error(e, attempt: 2, retried: false)
          raise
        end
        checkout_retried = true
        notify_error(e, attempt: 1, retried: true)
        sleep(checkout_delay)
        retry
      end
    end

    def disconnect!
      @pool.shutdown { |conn| safe_close(conn) }
    end

    # Redis INFO parsed to a Hash, with this pool's own `size` / `available`
    # slot counts merged in — one call gives a heartbeat both Redis health and
    # local pool saturation. (Real Redis INFO has no `size`/`available` field.)
    def info
      with { |conn| parse_info(conn.call('INFO')) }
        .merge('size' => @size, 'available' => available)
    end

    # Free (unchecked-out) slots right now. Local and cheap — no Redis round
    # trip — so a monitor can poll it without perturbing the pool.
    def available
      @pool.available
    end

    private

    # Socket config forwarded to redis-client. RedisOptions owns the translation
    # of the Sidekiq-shaped hash (network_timeout, master_name, pool-only keys,
    # …) so this class stays about pooling; host-supplied keys win over the
    # defaults.
    def build_client_config(options)
      RedisOptions.normalize(options, defaults: DEFAULT_CLIENT_CONFIG).freeze
    end

    # Wrapped in the CompatClient decorator so `Sidekiq.redis { |c| c.smembers }`
    # method-style commands work like Sidekiq 7+ (#204). Wurk's own code paths
    # use #call, which the decorator forwards.
    def build_client
      RedisClientAdapter::CompatClient.new(redis_client_config.new_client)
    end

    # A Sentinel set is a different constructor, not a different keyword:
    # `RedisClient.config(sentinels: [...])` raises. Sidekiq routes the same way.
    def redis_client_config
      if RedisOptions.sentinel?(@client_config)
        RedisClient.sentinel(**@client_config)
      else
        RedisClient.config(**@client_config)
      end
    end

    def safe_close(conn)
      conn.close
    rescue StandardError
      nil
    end

    # Runs the block on the checked-out `conn`, retrying transient RedisClient
    # errors in place: the same slot is reused across retries (redis-client
    # redials a closed socket lazily), so a busy fetcher can't leak checkouts.
    def run(conn)
      attempts = 0
      begin
        attempts += 1
        yield conn
      rescue RedisClient::Error => e
        plan = retry_plan(e, attempts)
        raise if plan == :propagate

        notify_error(e, attempt: attempts, retried: plan != :exhausted)
        raise if plan == :exhausted

        safe_close(conn)
        sleep(backoff_delay(attempts)) if plan == :backoff
        retry
      end
    end

    # Pure classification of a RedisClient error against the attempt count:
    #   :failover  → close + immediate retry (a primary swap)
    #   :backoff   → close + sleep + retry (a connection blip)
    #   :exhausted → ConnectionError past the cap; report and give up
    #   :propagate → not transient (or a spent failover); raise as-is
    def retry_plan(err, attempts)
      if RETRYABLE_MSG.match?(err.message.to_s)
        attempts > 1 ? :propagate : :failover
      elsif err.is_a?(RedisClient::ConnectionError)
        attempts >= CONN_MAX_ATTEMPTS ? :exhausted : :backoff
      else
        :propagate
      end
    end

    def notify_error(error, attempt:, retried:)
      return if @on_error.nil?

      @on_error.call({ error:, attempt:, retried:, pool: @name })
    rescue StandardError
      nil
    end

    def backoff_delay(attempt)
      (CONN_BACKOFF_BASE * (2**attempt)) + (rand * CONN_BACKOFF_JITTER)
    end

    def checkout_delay
      POOL_RETRY_MIN + (rand * POOL_RETRY_SPREAD)
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
