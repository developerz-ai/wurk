# frozen_string_literal: true

require 'socket'
require 'securerandom'

module Wurk
  # Shared mixin for runtime components (Launcher, Manager, Processor, Fetcher,
  # Scheduler, Cron). Wraps clock readings, identity, thread spawning,
  # lifecycle event dispatch, and exception forwarding so each component
  # stays single-purpose.
  #
  # Host class must expose `#config` returning either a Wurk::Configuration
  # or a Wurk::Capsule — both duck-type the methods we delegate to.
  #
  # Spec: docs/target/sidekiq-free.md §11 (Sidekiq::Component).
  module Component
    DEFAULT_THREAD_PRIORITY = -1

    # Stable for the life of the process — survives fork (children inherit
    # the same nonce). Identity differs across forks because Process.pid does.
    PROCESS_NONCE = SecureRandom.hex(6)

    attr_reader :config

    # `leader?` cache TTL — see the method doc below.
    LEADER_CACHE_TTL_MS = 5_000

    # --- clocks ---------------------------------------------------------

    def real_ms
      ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
    end

    def mono_ms
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :millisecond)
    end

    # --- identity -------------------------------------------------------

    # Base36 `thread.object_id ^ pid` — the id in every log line and the key
    # each Processor publishes its in-flight job under. Constant for the life
    # of a thread inside one process and read several times per job, so it is
    # memoized per thread (frozen: it is used as a Hash key, and an unfrozen
    # String key is duped on every store).
    #
    # The pid is memoized alongside it because the thread that calls fork keeps
    # its thread-locals in the child, where the pid — and therefore the tid —
    # has changed. Without the guard a forked child would report the parent's
    # tid and collide with it in `<identity>:work`.
    def self.tid
      memo = Thread.current[:wurk_tid]
      pid = ::Process.pid
      return memo[1] if memo && memo[0] == pid

      id = (Thread.current.object_id ^ pid).to_s(36).freeze
      Thread.current[:wurk_tid] = [pid, id].freeze
      id
    end

    def tid
      Component.tid
    end

    def hostname
      ENV['DYNO'] || Socket.gethostname
    end

    def process_nonce
      PROCESS_NONCE
    end

    def identity
      "#{hostname}:#{::Process.pid}:#{process_nonce}"
    end

    def default_tag(dir = Dir.pwd)
      File.basename(dir)
    end

    # --- delegated to config -------------------------------------------

    def logger
      config.logger
    end

    def redis(idempotent: false, &)
      config.redis(idempotent:, &)
    end

    def handle_exception(ex, ctx = {})
      config.handle_exception(ex, ctx)
    end

    # --- cluster leadership --------------------------------------------

    # True iff this process currently holds the cluster `dear-leader` lock.
    # Cached per Component instance for `LEADER_CACHE_TTL_MS` (~5s): cron and
    # the metrics rollups call this every tick, and an uncached GET would
    # double their Redis traffic at short intervals for no benefit — the
    # lock's own renewal cadence (60s+, spec §6.1) easily tolerates a
    # few-second-stale read. Returns false unconditionally when
    # `WURK_LEADER=false` (or `SIDEKIQ_LEADER=false`) is set on the process
    # (opt-out hot-standby). Any Redis error is swallowed → false, so a
    # transient partition can't propagate as an exception into user code.
    #
    # Spec: docs/target/sidekiq-ent.md §6.1.
    def leader?
      return false if Wurk::Leader.opted_out?

      now = mono_ms
      if @leader_checked_at.nil? || (now - @leader_checked_at) >= LEADER_CACHE_TTL_MS
        @leader_checked_at = now
        @leader_cached = fetch_leader?
      end
      @leader_cached
    end

    # --- thread boundaries ---------------------------------------------

    # Wraps a block at a thread boundary: any unhandled exception is reported
    # via handle_exception (so it lands in error_handlers / the log) and then
    # re-raised. `last_words` is the component label included in the context.
    def watchdog(last_words)
      yield
    rescue StandardError => e
      handle_exception(e, { context: last_words })
      raise
    end

    # Spawns a named thread that runs `block` under `watchdog(name)`. The
    # parent must retain the returned Thread; otherwise GC may not, but
    # report_on_exception is disabled so we don't double-log on death.
    def safe_thread(name, priority: nil, &block)
      Thread.new do
        Thread.current.name = name
        Thread.current.priority = priority || DEFAULT_THREAD_PRIORITY
        Thread.current.report_on_exception = false
        watchdog(name, &block)
      end
    end

    # Invokes lifecycle hooks for `event`. Hooks run in registration order
    # (or LIFO when `reverse: true`, used for teardown). A raise in one hook
    # is reported via handle_exception and does NOT stop the next hook unless
    # `reraise: true` (used in tests / fail-fast boot). `oneshot: true`
    # clears the bucket after dispatch so the event can't fire twice.
    def fire_event(event, oneshot: true, reverse: false, reraise: false)
      bucket = config[:lifecycle_events][event]
      return if bucket.nil? || bucket.empty?

      iter = reverse ? bucket.reverse : bucket
      iter.each { |hook| run_lifecycle_hook(hook, event, reraise) }
      bucket.clear if oneshot
    end

    private

    def fetch_leader?
      redis { |c| c.call('GET', Wurk::Leader::DEFAULT_KEY) } == identity
    rescue StandardError
      false
    end

    def run_lifecycle_hook(hook, event, reraise)
      hook.call
    rescue StandardError => e
      handle_exception(e, { event: event })
      raise if reraise
    end
  end
end
