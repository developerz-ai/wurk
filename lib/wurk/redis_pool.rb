# frozen_string_literal: true

require 'redis-client'
require 'connection_pool'
require_relative 'command_builder'
require_relative 'redis_client_adapter'
require_relative 'redis_options'

module Wurk
  # Per-process pool over redis-client + connection_pool. Never share a socket
  # across forks: the parent closes the pool before fork, each child opens a
  # fresh one (see docs/idea/03-process-model.md, steps 3 and 5).
  #
  # #with absorbs transient Redis failures (production incident #101), but only
  # where replaying the caller's block cannot change what the server already
  # did — the block is arbitrary Ruby, so a replay re-issues every command in it:
  #   * READONLY / NOREPLICAS / UNBLOCKED — a failover happened; close and retry
  #     once immediately so redis-client redials the new primary (spec §26).
  #   * CannotConnect / Failover — raised while dialing, so the command that hit
  #     one never reached a server and cannot have applied; close and retry with
  #     exponential backoff up to CONN_MAX_ATTEMPTS, then raise.
  #   * Read-/WriteTimeout and bare ConnectionError — the command may already
  #     have applied server-side, so the pool does not replay the block. That
  #     bounds block replay only: by the time one of these reaches the pool,
  #     redis-client has already re-sent the in-flight command once on a fresh
  #     socket (reconnect_attempts, see DEFAULT_RECONNECT_ATTEMPTS), so a lost
  #     reply can still double-apply that one command. Blocks that are safe to
  #     re-run (pure reads, an LMOVE the reaper reclaims, owner-CAS scripts) opt
  #     back into the backoff with `with(idempotent: true)`.
  #   * ConnectionPool::TimeoutError — checkout starved; retry once after a
  #     short jittered pause, then raise (sizing is the fix, not queuing). Only
  #     a checkout of *this* pool that never handed out a connection retries: the
  #     same error escaping a nested checkout of another pool from inside the
  #     block is raised as-is, because the block's earlier commands have run.
  # Those proofs are about the command that raised, not the block around it: a
  # block is several round trips, and redis-client re-dials mid-block, so a
  # CannotConnect can surface on the second pipeline of a block whose first one
  # already landed. So the pool also watches the connection's round-trip
  # odometer (RedisClientAdapter::CompatClient#round_trips) and refuses to
  # replay a non-idempotent block that has already completed one.
  # Every retry, refused replay, and final give-up is reported through the
  # injected `on_error` telemetry hook (Wurk::Configuration#on_redis_error).
  class RedisPool
    DEFAULT_URL  = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
    DEFAULT_NAME = 'default'

    # ConnectionPool checkout wait — how long #with blocks for a free slot.
    DEFAULT_POOL_TIMEOUT = 1.0

    # Socket-level timeouts handed to RedisClient, split apart from the checkout
    # wait above. read/write are deliberately wider than connect so a briefly-
    # slow-but-alive Redis (RDB fork pause, a large BLMOVE payload) doesn't
    # spuriously ReadTimeout — the production incident (#101) the single
    # dual-use timeout caused.
    #
    # 0 closes the duplicate-application window. With 1 (Sidekiq's setting,
    # mirrored upstream) a reply lost mid-command is re-sent onto a fresh
    # socket by redis-client and can land that one command twice: a duplicate
    # LPUSH, a double INCR, a ZPOPBYSCORE whose first pop is lost with its
    # reply (Sidekiq #3303 — the same upstream exposure the default has).
    # A stale socket now surfaces as a connect-phase ConnectionError, which
    # the pool's pre-apply retry (the same backoff a `:failover` or
    # `idempotent: true` block uses) replays onto a fresh socket. Diverges
    # from Sidekiq's `reconnect_attempts ||= 1`; pinned here so a rethink
    # has to break this comment AND `test_default_reconnect_attempts`.
    DEFAULT_CONNECT_TIMEOUT    = 1.0
    DEFAULT_READ_TIMEOUT       = 2.5
    DEFAULT_WRITE_TIMEOUT      = 2.5
    DEFAULT_RECONNECT_ATTEMPTS = 0

    # The floor every pool starts from; any key the host passed wins over it —
    # including `command_builder`, so an app that has its own keeps it.
    DEFAULT_CLIENT_CONFIG = {
      url: DEFAULT_URL,
      connect_timeout: DEFAULT_CONNECT_TIMEOUT,
      read_timeout: DEFAULT_READ_TIMEOUT,
      write_timeout: DEFAULT_WRITE_TIMEOUT,
      reconnect_attempts: DEFAULT_RECONNECT_ATTEMPTS,
      command_builder: CommandBuilder
    }.freeze

    # Server-side messages where the connection is closed and the block retried
    # exactly once. READONLY is itself a RedisClient::ConnectionError subclass,
    # so this message match must be tested BEFORE the generic ConnectionError
    # backoff below (otherwise a failover would sleep instead of redialing).
    RETRYABLE_MSG = /\A(READONLY|NOREPLICAS|UNBLOCKED)/

    # ConnectionErrors that can only be raised while dialing, so the block
    # provably never applied and replaying it is safe whatever it contains.
    # CannotConnect covers every connect-phase failure (redis-client converts a
    # stalled handshake into it); Failover is the Sentinel resolver rejecting a
    # server whose role changed. Any other ConnectionError — Read-/WriteTimeout
    # or a reset mid-command — leaves the outcome unknown.
    PRE_APPLY_ERRORS = [RedisClient::CannotConnectError, RedisClient::FailoverError].freeze

    # The two retry_plan verdicts that re-run the block; the rest raise.
    REPLAY_PLANS = %i[failover backoff].freeze

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

    # Idle reaping (`:redis_idle_timeout`) sweeps at half the timeout, so a
    # connection is closed within 1.5x of going idle, but never less often than
    # this — Sidekiq reaps on its 10s heartbeat.
    REAP_MAX_INTERVAL = 10.0

    attr_reader :size, :url, :name, :pool_timeout, :client_config, :redis_idle_timeout

    # Takes the standard Sidekiq `config.redis` hash: `pool_timeout` tunes the
    # ConnectionPool checkout; `connect_timeout`/`read_timeout`/`write_timeout`/
    # `reconnect_attempts` plus any other redis-client key (driver, ssl_params,
    # sentinels, …) reach the client. Sidekiq-only spellings (`network_timeout`,
    # `master_name`, `logger`, …) are translated or dropped by {RedisOptions};
    # a key redis-client would reject raises there with the key named.
    # `on_error` is an optional callable fired per retry / final give-up with
    # { error:, attempt:, retried:, pool: }.
    #
    # `redis_idle_timeout` (seconds, Wurk::Configuration[:redis_idle_timeout])
    # closes a checked-in connection once it has sat unused that long; the next
    # checkout dials a fresh one. It is not redis-client's own `idle_timeout`,
    # which only re-validates a stale socket with a PING and stays a
    # `config.redis` key.
    def initialize(size:, name: DEFAULT_NAME, on_error: nil, redis_idle_timeout: nil, **options)
      @size               = size
      @name               = name
      @on_error           = on_error
      @redis_idle_timeout = self.class.validate_idle_timeout(redis_idle_timeout)
      @pool_timeout       = options.fetch(:pool_timeout, DEFAULT_POOL_TIMEOUT)
      @client_config      = build_client_config(options)
      @url                = @client_config[:url]
      @pool               = ConnectionPool.new(size: size, timeout: @pool_timeout) { build_client }
      @reaper_lock        = Thread::Mutex.new
      @reaper             = nil
      @reaper_closed      = false
    end

    # Checkout a connection and run the block. Our own checkout raises
    # ConnectionPool::TimeoutError *before* the block runs, so it is caught out
    # here (the in-block #run rescue never sees it) — one retry, then raise.
    # `entered` tells that apart from the same class escaping the block — a
    # nested checkout of another, starved pool — where the block's earlier
    # commands already ran and a replay would re-issue them (an INCR counted
    # twice, a job pushed twice).
    #
    # `idempotent: true` asserts the block can be re-run after a command may
    # already have applied server-side, which buys back the full ConnectionError
    # backoff. Only claim it for pure reads or writes whose repeat is a no-op.
    def with(idempotent: false, &block)
      ensure_reaper if @redis_idle_timeout
      checkout_retried = false
      entered = false
      begin
        @pool.with do |conn|
          entered = true
          run(conn, idempotent, &block)
        end
      rescue ConnectionPool::TimeoutError => e
        raise if entered

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
      stop_reaper
      @pool.shutdown { |conn| safe_close(conn) }
    end

    # Redis INFO parsed to a Hash, with this pool's own `size` / `available`
    # slot counts merged in — one call gives a heartbeat both Redis health and
    # local pool saturation. (Real Redis INFO has no `size`/`available` field.)
    def info
      with(idempotent: true) { |conn| parse_info(conn.call('INFO')) }
        .merge('size' => @size, 'available' => available)
    end

    # Free (unchecked-out) slots right now. Local and cheap — no Redis round
    # trip — so a monitor can poll it without perturbing the pool.
    # A reaped connection's slot stays free, so reaping leaves this count where
    # it was; #idle is the number that drops.
    def available
      @pool.available
    end

    # Open connections sitting checked in — what idle reaping closes.
    def idle
      @pool.idle
    end

    # Checked here as well as by connection_pool, whose own ArgumentError would
    # only surface inside the reaper thread and silently end it. Configuration
    # calls it too, so a bad value fails in the parent instead of crash-looping
    # every forked child.
    def self.validate_idle_timeout(seconds)
      return nil if seconds.nil?
      return seconds if seconds.is_a?(Numeric) && seconds.positive?

      raise ArgumentError, "redis_idle_timeout must be a positive number of seconds or nil, got #{seconds.inspect}"
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

    # Started lazily on the first checkout rather than in #initialize, so it
    # always runs in the process that owns the connections: a thread does not
    # survive fork (an inherited reaper reads as dead in the child), and a pool
    # a child inherited — whose connections connection_pool drops after fork —
    # gets a reaper of its own. Thread#alive? rather than a pid compare keeps
    # the per-checkout cost off a getpid syscall.
    def ensure_reaper
      return if @reaper&.alive?

      @reaper_lock.synchronize do
        return if @reaper_closed || @reaper&.alive?

        @reaper_stop = Thread::Queue.new
        @reaper      = Thread.new(@reaper_stop) { |stop| reap_loop(stop) }
        @reaper.name = "wurk-redis-reaper-#{@name}"
      end
    end

    def stop_reaper
      reaper = @reaper_lock.synchronize do
        @reaper_closed = true
        next unless @reaper&.alive?

        @reaper_stop << true
        @reaper
      end
      reaper&.join
    end

    # connection_pool removes each expired connection from the idle stack under
    # its own lock before yielding it, so the close can never race a checkout:
    # a checked-out connection is not on that stack to be found. #disconnect!
    # joins this thread before shutting the pool down, so a sweep never meets a
    # pool mid-shutdown.
    def reap_loop(stop)
      interval = [@redis_idle_timeout / 2.0, REAP_MAX_INTERVAL].min
      @pool.reap(idle_seconds: @redis_idle_timeout) { |conn| safe_close(conn) } until stop.pop(timeout: interval)
    end

    # Runs the block on the checked-out `conn`, retrying transient RedisClient
    # errors in place: the same slot is reused across retries (redis-client
    # redials a closed socket lazily), so a busy fetcher can't leak checkouts.
    def run(conn, idempotent)
      attempts = 0
      odometer = conn.round_trips
      begin
        attempts += 1
        yield conn
      rescue RedisClient::Error => e
        plan = retry_plan(e, attempts, idempotent, conn.round_trips != odometer)
        raise if plan == :propagate

        replaying = REPLAY_PLANS.include?(plan)
        notify_error(e, attempt: attempts, retried: replaying)
        raise unless replaying

        safe_close(conn)
        sleep(backoff_delay(attempts)) if plan == :backoff
        odometer = conn.round_trips
        retry
      end
    end

    # Pure classification of a RedisClient error against the attempt count, the
    # caller's apply-safety claim, and whether this attempt already completed a
    # round trip (`dirty`):
    #   :failover  → close + immediate retry (a primary swap)
    #   :backoff   → close + sleep + retry (a connection blip)
    #   :unsafe    → something may have applied; report the blip, then raise
    #   :exhausted → replayable ConnectionError past the cap; report and give up
    #   :propagate → not transient (or a spent failover); raise as-is
    def retry_plan(err, attempts, idempotent, dirty)
      failover = RETRYABLE_MSG.match?(err.message.to_s)
      return :propagate unless failover || err.is_a?(RedisClient::ConnectionError)
      return :unsafe unless replayable?(err, idempotent, dirty, failover)
      return attempts > 1 ? :propagate : :failover if failover

      attempts >= CONN_MAX_ATTEMPTS ? :exhausted : :backoff
    end

    # A replay re-issues the whole block, so one completed round trip voids
    # every pre-apply proof: however provably the *failing* command missed the
    # server, the ones ahead of it in the block did not. On a still-clean block
    # a failover reply is proof enough by itself (the command was rejected
    # outright); a bare ConnectionError needs one of the connect-phase classes.
    def replayable?(err, idempotent, dirty, failover)
      return true if idempotent
      return false if dirty

      failover || PRE_APPLY_ERRORS.any? { |klass| err.is_a?(klass) }
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
