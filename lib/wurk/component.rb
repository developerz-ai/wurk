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

    # --- clocks ---------------------------------------------------------

    def real_ms
      ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
    end

    def mono_ms
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :millisecond)
    end

    # --- identity -------------------------------------------------------

    def tid
      (Thread.current.object_id ^ ::Process.pid).to_s(36)
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

    def redis(&)
      config.redis(&)
    end

    def handle_exception(ex, ctx = {})
      config.handle_exception(ex, ctx)
    end

    # --- cluster leadership --------------------------------------------

    # True iff this process currently holds the cluster `dear-leader` lock.
    # Per spec, the check is performed at call time (Wurk does not cache);
    # callers must not poll faster than the 60s follower cadence. Returns
    # false unconditionally when `WURK_LEADER=false` (or `SIDEKIQ_LEADER=false`)
    # is set on the process (opt-out hot-standby). Any Redis error is swallowed →
    # false, so a transient partition can't propagate as an exception into user
    # code.
    #
    # Spec: docs/target/sidekiq-ent.md §6.1.
    def leader?
      return false if Wurk::Leader.opted_out?

      redis { |c| c.call('GET', Wurk::Leader::DEFAULT_KEY) } == identity
    rescue StandardError
      false
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

    def run_lifecycle_hook(hook, event, reraise)
      hook.call
    rescue StandardError => e
      handle_exception(e, { event: event })
      raise if reraise
    end
  end
end
