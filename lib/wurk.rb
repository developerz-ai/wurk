# frozen_string_literal: true

# Standalone entry point. Loading "wurk" must work without Rails.
# The engine and railtie live under "wurk/rails" and are only loaded
# when the host app opts in.

require_relative 'wurk/version'
require_relative 'wurk/keys'
require_relative 'wurk/redis_pool'
require_relative 'wurk/middleware'
require_relative 'wurk/middleware/chain'
require_relative 'wurk/component'
require_relative 'wurk/context'
require_relative 'wurk/logger'
require_relative 'wurk/job_logger'
require_relative 'wurk/capsule'
require_relative 'wurk/configuration'
require_relative 'wurk/job_util'
require_relative 'wurk/client'
require_relative 'wurk/client/buffered'
require_relative 'wurk/worker'
require_relative 'wurk/worker/setter'
require_relative 'wurk/job'
require_relative 'wurk/job/options'
require_relative 'wurk/iterable_job'
require_relative 'wurk/job_retry'
require_relative 'wurk/job_record'
require_relative 'wurk/queue'
require_relative 'wurk/sorted_entry'
require_relative 'wurk/job_set'
require_relative 'wurk/retry_set'
require_relative 'wurk/scheduled_set'
require_relative 'wurk/dead_set'
require_relative 'wurk/stats'
require_relative 'wurk/process_set'
require_relative 'wurk/work_set'
require_relative 'wurk/heartbeat'
require_relative 'wurk/fetcher'
require_relative 'wurk/fetcher/reliable'
require_relative 'wurk/processor'
require_relative 'wurk/manager'
require_relative 'wurk/lua'
require_relative 'wurk/scheduled'
require_relative 'wurk/launcher'
require_relative 'wurk/cli'
require_relative 'wurk/embedded'
require_relative 'wurk/swarm'
require_relative 'wurk/topology'
require_relative 'wurk/batch'
require_relative 'wurk/batch/status'
require_relative 'wurk/batch_set'
require_relative 'wurk/limiter'
require_relative 'wurk/cron'
require_relative 'wurk/leader'
require_relative 'wurk/unique'
require_relative 'wurk/encryption'
require_relative 'wurk/metrics'
require_relative 'wurk/metrics/statsd'
require_relative 'wurk/metrics/history'
require_relative 'wurk/metrics/query'
require_relative 'wurk/web'
require_relative 'wurk/deploy'

require 'json'

module Wurk
  class Error < StandardError; end

  # Raised inside a worker process to abort the run loop. User code must not
  # rescue this — the swarm uses it to signal teardown across thread boundaries.
  # Spec: docs/target/sidekiq-free.md §3.
  class Shutdown < Interrupt; end

  # Process-wide job option defaults. Per-class options from `sidekiq_options`
  # take precedence; this hash is the floor.
  DEFAULT_JOB_OPTIONS = { 'retry' => true, 'queue' => 'default' }.freeze

  class << self
    def configure_server(&)
      configuration.configure_server(&)
    end

    def configure_client(&)
      configuration.configure_client(&)
    end

    # Embedded mode: caller runs Wurk inside its own process (Puma, rake task,
    # etc.) without forking. Concurrency is defaulted to 2 — the GIL makes
    # higher thread counts counterproductive inside a host process that has
    # its own pool. The block can override anything before the Embedded
    # instance is built. Returns a Wurk::Embedded the caller drives with
    # `#run` / `#quiet` / `#stop`.
    def configure_embed
      if configuration.frozen?
        raise FrozenError, 'Wurk configuration is frozen; build all embedded instances before calling run'
      end

      configuration.concurrency = 2
      yield configuration if block_given?
      Embedded.new(configuration)
    end

    def configuration
      @configuration ||= Configuration.new
    end
    alias default_configuration configuration

    def redis(&)
      redis_pool.with(&)
    end

    # Capsule-aware pool lookup. Thread-local override wins so per-capsule
    # workers (`Thread.current[:wurk_capsule] = cap`) read from their own
    # connections without leaking to the default capsule.
    def redis_pool
      (Thread.current[:wurk_capsule] || configuration.default_capsule).redis_pool
    end

    def logger
      configuration.logger
    end

    # --- JSON ---------------------------------------------------------

    def load_json(string)
      ::JSON.parse(string)
    end

    def dump_json(object)
      ::JSON.generate(object)
    end

    # --- default job options -----------------------------------------

    def default_job_options
      @default_job_options ||= DEFAULT_JOB_OPTIONS.dup
    end

    # Merges (does not replace) into the current defaults. Keys are
    # stringified so symbol-keyed callers don't shadow string keys.
    def default_job_options=(hash)
      @default_job_options = default_job_options.merge(hash.transform_keys(&:to_s))
    end

    # --- strict args -------------------------------------------------

    # Sets the global mode used by Wurk::JobUtil#verify_json.
    # mode ∈ [:raise, :warn, false].
    def strict_args!(mode = :raise)
      @strict_args_mode = mode
    end

    # `defined?` distinguishes "never set" from "set to false".
    def strict_args_mode
      defined?(@strict_args_mode) ? @strict_args_mode : Configuration::DEFAULTS[:on_complex_arguments]
    end

    # --- mode flags --------------------------------------------------

    # Sets the testing mode. Real behavior (inline/fake/disable) is wired
    # up when the test harness loads; this just records the setting.
    def testing!(mode = :fake)
      @testing_mode = mode
      return @testing_mode unless block_given?

      begin
        yield
      ensure
        @testing_mode = nil
      end
    end

    def testing?
      !!@testing_mode
    end

    # True inside the swarm/manager process (set by exe/wurk / the railtie).
    def server?
      !!@server
    end

    attr_writer :server

    # Wurk ships Pro+Ent features in the free gem; these flags exist solely
    # for third-party gems that branch on Sidekiq.pro? / Sidekiq.ent?.
    def pro?
      false
    end

    def ent?
      false
    end
  end
end

# Batch worker classes (Empty, CallbackJob) and middleware load AFTER the
# Wurk module class << self block — they instantiate workers at load time
# via `sidekiq_options`, which reads Wurk.default_job_options.
require_relative 'wurk/batch/empty'
require_relative 'wurk/batch/callback_job'
require_relative 'wurk/batch/callbacks'
require_relative 'wurk/batch/client_middleware'
require_relative 'wurk/batch/server_middleware'
require_relative 'wurk/batch/death_handler'

# Expiry must register AFTER Batch::ServerMiddleware so it sits inside that
# middleware's onion — a skipped (expired) job then unwinds back through
# batch's `yield` and gets counted as a batch success on the way out.
# Spec: docs/target/sidekiq-pro.md §7.
require_relative 'wurk/middleware/expiry'

# Poison-pill detection — orphan recovery counter + dead set on threshold.
# Spec: docs/target/sidekiq-pro.md §3.2.
require_relative 'wurk/middleware/poison_pill'

# Limiter server middleware: catches OverLimit, reschedules onto the same
# queue with `Time.now + backoff` until `overrated` hits the reschedule cap.
# Registered AFTER Batch::ServerMiddleware so a rescheduled OverLimit
# unwinds back through the batch onion without ack'ing success.
# Spec: docs/target/sidekiq-ent.md §1.4.
Wurk.configuration.server_middleware.add(Wurk::Limiter::ServerMiddleware)

# Pro Fast API: Lua-backed Queue#delete_job / #delete_by_class plus
# SortedSet#scan { |JobRecord| … }. Mixed in via include/prepend on the
# existing data API classes so the surface is wire-compat with Sidekiq Pro.
# Spec: docs/target/sidekiq-pro.md §11.
require_relative 'wurk/api/fast'

# Sidekiq aliases load last — every Wurk::* constant they reference must be
# fully defined first. compat.rb only redefines names, it does not gate
# behavior, so trailing the load order is safe.
require_relative 'wurk/compat'
