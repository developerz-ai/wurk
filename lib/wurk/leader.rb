# frozen_string_literal: true

require 'securerandom'
require 'socket'
require_relative 'component'
require_relative 'pool_checkout'

module Wurk
  # Cluster leader election via Redis `SET NX EX`. Single-leader-per-cluster
  # is best-effort (not Raft): a partitioned ex-leader can briefly co-exist
  # with a new one until the TTL expires. Callers that need strict mutual
  # exclusion must idempotency-guard their writes (see `#token`).
  #
  # Wire-compat: the cluster lock lives at `dear-leader` (STRING, EX≈30s)
  # holding the `<hostname>:<pid>:<process_nonce>` identity. Each fresh
  # gain also pulls a monotonic fencing token via `INCR leader-token`,
  # exposed on `#token`. Wurk goes a small step beyond Sidekiq Enterprise
  # (which deliberately does not expose fencing) so downstream code that
  # *can* benefit from a guard has one available; the token is best-effort
  # too — it is never re-read on subsequent acquires, only on transitions.
  #
  # Cadence per spec: renew every 15s while leader, recheck every 60s as
  # follower, lock TTL 30s. Opt out a process from campaigning entirely
  # with `WURK_LEADER=false` (or its Sidekiq alias `SIDEKIQ_LEADER=false`),
  # useful for hot-standby pools.
  #
  # Spec: docs/target/sidekiq-ent.md §6.
  class Leader
    DEFAULT_KEY = 'dear-leader'
    TOKEN_KEY = 'leader-token'
    DEFAULT_TTL = 30
    DEFAULT_RENEW_INTERVAL = 15
    DEFAULT_FOLLOWER_INTERVAL = 60
    OPT_OUT_ENV = 'WURK_LEADER'            # native opt-out env
    SIDEKIQ_OPT_OUT_ENV = 'SIDEKIQ_LEADER' # Sidekiq Ent drop-in alias (§6.2/§7.2)
    THREAD_NAME = 'wurk-leader'

    # True when this process has opted out of campaigning via `WURK_LEADER=false`
    # or its Sidekiq alias `SIDEKIQ_LEADER=false` (hot-standby pools that must
    # never lead). Either env name works.
    def self.opted_out?
      [OPT_OUT_ENV, SIDEKIQ_OPT_OUT_ENV].any? { |k| ENV[k].to_s.downcase == 'false' }
    end

    attr_reader :key, :ttl, :owner, :token, :config

    def initialize(config: nil, key: DEFAULT_KEY, ttl: DEFAULT_TTL, # rubocop:disable Metrics/ParameterLists
                   renew_interval: DEFAULT_RENEW_INTERVAL,
                   follower_interval: DEFAULT_FOLLOWER_INTERVAL,
                   pool: nil, owner: nil)
      @config = config
      @key = key
      @ttl = ttl
      @renew_interval = renew_interval
      @follower_interval = follower_interval
      @pool = pool
      @owner = owner || cluster_identity
      @held = false
      @token = nil
      @thread = nil
      @done = false
      @mutex = ::Mutex.new
      @sleeper = ::ConditionVariable.new
    end

    # `WURK_LEADER=false` (or `SIDEKIQ_LEADER=false`) makes `acquire` a no-op and
    # `leader?` permanently false; the renewal thread also refuses to start.
    # Useful for hot-standby pools that must never campaign.
    def disabled?
      self.class.opted_out?
    end

    # SET NX EX. If the key already holds *our* owner string (rare — same
    # process re-entering after a hiccup), refresh via EXPIRE so leadership
    # doesn't lapse. On any follower → leader transition, INCR the global
    # `leader-token` so the new token is strictly greater than every prior
    # leader's, then dispatch the `:leader` lifecycle event.
    def acquire # rubocop:disable Naming/PredicateMethod
      return false if disabled?

      transition = run_set_or_refresh
      return false unless transition

      if transition == :gained
        @token = redis_call { |c| c.call('INCR', TOKEN_KEY) }
        dispatch_leader_event
      end
      true
    end

    # CAS DEL — only drop the key if we still own it, otherwise a stale
    # release would yank leadership from whichever follower took over.
    def release
      redis_call do |c|
        c.call('DEL', @key) if c.call('GET', @key) == @owner
      end
      @held = false
      @token = nil
      nil
    end

    def leader?
      @held
    end

    # Spawns the periodic re-election thread. Idempotent. While leader,
    # the loop re-acquires (refreshing TTL) every `renew_interval`; while
    # follower, it polls every `follower_interval`. Caller must invoke
    # `stop` for orderly shutdown — the thread also releases its lock on
    # exit.
    def start
      return nil if disabled?

      @mutex.synchronize do
        return @thread if @thread

        @done = false
      end
      @thread = spawn_loop_thread
    end

    def stop
      @mutex.synchronize do
        @done = true
        @sleeper.signal
      end
      @thread&.join
      @thread = nil
      release
    end

    def running?
      !@thread.nil? && @thread.alive?
    end

    private

    # Returns `:gained` on first acquisition, `:held` on renewal, or `nil`
    # if another process currently holds the key. Sets `@held` accordingly
    # so `leader?` reflects the latest state regardless of branch.
    def run_set_or_refresh
      redis_call do |c|
        result = c.call('SET', @key, @owner, 'NX', 'EX', @ttl)
        if result == 'OK'
          outcome = @held ? :held : :gained
          @held = true
          return outcome
        end

        if c.call('GET', @key) == @owner
          c.call('EXPIRE', @key, @ttl)
          outcome = @held ? :held : :gained
          @held = true
          return outcome
        end

        @held = false
        @token = nil
        nil
      end
    end

    def dispatch_leader_event
      return if @config.nil?
      return unless @config.respond_to?(:[])

      bucket = @config[:lifecycle_events]&.[](:leader)
      return if bucket.nil? || bucket.empty?

      bucket.each { |hook| invoke_hook(hook) }
    end

    def invoke_hook(hook)
      hook.call
    rescue StandardError => e
      @config.handle_exception(e, event: :leader) if @config.respond_to?(:handle_exception)
    end

    def redis_call(idempotent: false, &)
      if @pool
        PoolCheckout.with(@pool, idempotent, &)
      elsif @config
        @config.redis(idempotent:, &)
      else
        Wurk.redis(idempotent:, &)
      end
    end

    # Matches `Wurk::Component#identity` so `ProcessSet::Process#leader?`
    # (which compares `dear-leader == process.identity`) sees a match.
    def cluster_identity
      "#{hostname}:#{::Process.pid}:#{Component::PROCESS_NONCE}"
    end

    def hostname
      ENV['DYNO'] || ::Socket.gethostname
    rescue StandardError
      'localhost'
    end

    def spawn_loop_thread
      t = Thread.new { run_loop }
      t.name = THREAD_NAME
      t.report_on_exception = false
      t
    end

    def run_loop
      until done?
        tick_once
        wait_next
      end
      release
    end

    def tick_once
      acquire
    rescue StandardError => e
      @config.handle_exception(e, context: THREAD_NAME) if @config.respond_to?(:handle_exception)
    end

    def wait_next
      interval = @held ? @renew_interval : @follower_interval
      @mutex.synchronize { @sleeper.wait(@mutex, interval) unless @done }
    end

    def done?
      @mutex.synchronize { @done }
    end
  end
end
