# frozen_string_literal: true

# Standalone entry point. Loading "wurk" must work without Rails.
# The engine and railtie live under "wurk/rails"; they're auto-loaded at the
# end of this file when Rails is present (drop-in parity, #246), and stay
# unloaded otherwise so a no-Rails boot pulls in zero Rails code.

require_relative 'wurk/errors'
require_relative 'wurk/version'
require_relative 'wurk/keys'
require_relative 'wurk/redis_pool'
require_relative 'wurk/pool_checkout'
require_relative 'wurk/redis_connection'
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
require_relative 'wurk/transaction_aware_client'
require_relative 'wurk/worker'
require_relative 'wurk/worker/setter'
require_relative 'wurk/job'
require_relative 'wurk/job/options'
require_relative 'wurk/queues'
require_relative 'wurk/testing'
require_relative 'wurk/iterable_job'
require_relative 'wurk/iterable_job_query'
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
require_relative 'wurk/profiler'
require_relative 'wurk/profile_set'
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
require_relative 'wurk/flow'
require_relative 'wurk/flow_set'
require_relative 'wurk/limiter'
require_relative 'wurk/cron'
require_relative 'wurk/leader'
require_relative 'wurk/history'
require_relative 'wurk/unique'
require_relative 'wurk/debounce'
require_relative 'wurk/throttle'
require_relative 'wurk/queue_slot'
require_relative 'wurk/encryption'
require_relative 'wurk/status'
require_relative 'wurk/metrics'
require_relative 'wurk/metrics/statsd'
require_relative 'wurk/metrics/history'
require_relative 'wurk/metrics/query'
require_relative 'wurk/web'
require_relative 'wurk/deploy'

require 'json'

# Wurk — a 100% API-compatible, free drop-in for Sidekiq + Sidekiq Pro
# + Sidekiq Enterprise. Same Redis key schema, same job JSON, same Ruby DSL;
# real parallelism via a fork-based swarm. Every public class is also exposed
# under its `Sidekiq::*` name (see {Sidekiq}).
#
# Start here:
#   * {Wurk::Worker} / `Sidekiq::Job` — define and enqueue jobs.
#   * {Wurk::Configuration} — `Wurk.configure_server { |config| ... }`; note
#     `WURK_COUNT` (forked processes) × `concurrency` (threads) = total in-flight.
#   * {Wurk::Batch}, {Wurk::Limiter}, {Wurk::Unique} — Pro/Enterprise features, free.
#
# @see https://github.com/developerz-ai/wurk/blob/main/docs/migrate-from-sidekiq.md Migration guide
module Wurk
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

    # `idempotent: true` asserts the block is safe to re-run after a command may
    # already have applied server-side, buying back the full connection backoff
    # (see RedisPool#with). Every wrapper down the chain — Capsule,
    # Configuration, Component, middleware, Sidekiq.redis — forwards it, so a
    # caller can claim apply-safety wherever it holds; PoolCheckout drops the
    # claim for a host-supplied pool that wouldn't understand it. The zero-arg
    # shape is the drop-in contract: `Sidekiq.redis { |c| ... }` never changes.
    def redis(idempotent: false, &)
      PoolCheckout.with(redis_pool, idempotent, &)
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

    def logger=(logger)
      configuration.logger = logger
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

    # Opt in to enqueue-after-commit globally: every `perform_async` builds a
    # Wurk::TransactionAwareClient that defers its push to the surrounding
    # ActiveRecord transaction's commit. Idempotent. Spec: sidekiq-free.md §3.
    def transactional_push!
      default_job_options['client_class'] = Wurk::TransactionAwareClient
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

    # Sidekiq-compatible test-mode entry point. Delegates to Wurk::Testing
    # (the single source of truth for the mode): a block scopes the mode to the
    # current thread; no block sets it globally. `Sidekiq.testing!` aliases here.
    def testing!(mode = :fake, &) = Wurk::Testing.__set_test_mode(mode, &)

    # True when in :fake or :inline mode (i.e. not pushing to real Redis).
    def testing? = Wurk::Testing.enabled?

    # True inside the swarm/manager process (set by exe/wurk / the railtie).
    def server?
      !!@server
    end

    attr_writer :server

    # Enter server mode: set the module flag (read by third-party gems via
    # `Sidekiq.server?`) AND the per-config `server?` predicate that gates
    # `configure_server`. Both must be set before the app's initializers run,
    # or `configure_server` blocks (server middleware, error handlers,
    # lifecycle hooks) are silently skipped. Defaults to the global config; the
    # CLI passes its own (possibly test-injected) Configuration instance.
    def enter_server_mode(config = configuration)
      @server = true
      config[:server] = true
    end

    # Wurk ships Pro+Ent features in the free gem; these flags exist solely
    # for third-party gems that branch on Sidekiq.pro? / Sidekiq.ent?.
    def pro?
      false
    end

    def ent?
      false
    end

    # Lazily loads the Rails engine the first time something asks for
    # `Wurk::Engine`. See the note above the `require "wurk/rails"` guard at the
    # bottom of this file for why the guard alone isn't enough (#282), and why
    # this loads the engine and not the railtie.
    def const_missing(name)
      return super unless name == :Engine
      return super unless defined?(::Rails::Engine) && defined?(::ActionDispatch::Routing::RouteSet)

      require_relative 'wurk/engine'
      # If engine.rb somehow didn't define it, fall through to the real NameError
      # rather than recursing back into here.
      return super unless const_defined?(:Engine, false)

      const_get(:Engine, false)
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

# Collapse policies — `sidekiq_options collapse: { policy: :debounce, wait: 5 }`,
# a Wurk extra with no Sidekiq counterpart. Registered here rather than as a
# load-time side effect of collapse.rb, which worker.rb pulls in far earlier: the
# decision has to be taken on the way *out* of the chain, so the payload it
# writes to `schedule` carries whatever the middleware inside it stamped on. That
# only works from the outermost slot, and prepending here — after Batch has
# prepended its own `bid` stamp, which this then wraps, and before any
# host-installed `Unique.enable!` / `Encryption.enable!` / `Telemetry.install!`
# appends inside it — is what puts it there and keeps it there.
Wurk.configuration.client_middleware.prepend(Wurk::Collapse::ClientMiddleware)

# Expiry must register AFTER Batch::ServerMiddleware so it sits inside that
# middleware's onion — a skipped (expired) job then unwinds back through
# batch's `yield` and gets counted as a batch success on the way out.
# Spec: docs/target/sidekiq-pro.md §7.
require_relative 'wurk/middleware/expiry'

# Health probe HTTP server — opt-in via `config.health_check(port:)`. Loaded
# at top level so the constants resolve in Launcher#build_health_server even
# in standalone (no-Rails) boot.
require_relative 'wurk/health'

# Poison-pill detection — orphan recovery counter + dead set on threshold.
# Spec: docs/target/sidekiq-pro.md §3.2.
require_relative 'wurk/middleware/poison_pill'

# InterruptHandler self-prepends to the head of the server chain so a
# cooperatively-cancelled job (IterableJob) is re-pushed + cleanly skipped
# instead of surfacing as a raw error. Sidekiq registers it from
# `require "sidekiq/cli"`; we require it here at load so every server boot
# path picks it up — standalone CLI, embedded, and swarm-forked children
# (the swarm and embedded paths never run through Wurk::CLI#run).
# Spec: docs/target/sidekiq-free.md §10.3.
require_relative 'wurk/middleware/interrupt_handler'

# Limiter server middleware: catches OverLimit, reschedules onto the same
# queue with `Time.now + backoff` until `overrated` hits the reschedule cap.
# Registered AFTER Batch::ServerMiddleware, so in the chain Batch is OUTER
# and Limiter is INNER (`add` appends; entry 0 is outermost). A reschedule
# therefore unwinds *outward through* the batch onion — which is why it
# raises `Limiter::Rescheduled` (a JobRetry::Skip) rather than returning: a
# normal return would make the outer Batch middleware ack success for a job
# that never ran. The Skip signal makes Batch skip both acks instead.
# Spec: docs/target/sidekiq-ent.md §1.4.
Wurk.configuration.server_middleware.add(Wurk::Limiter::ServerMiddleware)

# Per-attempt wall-clock bound — `sidekiq_options timeout: 30`, a Wurk extra
# with no Sidekiq counterpart. Sits here for both of its neighbours: INSIDE
# Limiter, so the watchdog's raise can never land between Limiter's reschedule
# and the `Rescheduled` it raises after it (a job both rescheduled *and*
# retried), and OUTSIDE the three middleware below, so a timeout unwinds
# through Statsd, History and Status and is booked as the failure it is.
require_relative 'wurk/middleware/timeout'

# Statsd metrics middleware: per-job count / success / failure / perform_dist
# emissions. No-op when `config.dogstatsd` is unset (Statsd.client returns
# nil and the middleware yields straight through), so auto-registering here
# has zero overhead for users who don't wire up a client. Matches Sidekiq
# Pro's behavior of installing the middleware as soon as the gem is loaded.
# Spec: docs/target/sidekiq-pro.md §9.
Wurk.configuration.server_middleware.add(Wurk::Metrics::Statsd)

# Historical metrics middleware: records per-class processed/failed/ms into
# Redis time-buckets so the dashboard history pane has data on a default boot.
# Sidekiq auto-installs `Sidekiq::Metrics::Middleware` on the server for
# embedded/CLI; we mirror that here at load. Runs server-side only (the chain
# never executes in a client-only process). Spec: docs/target/sidekiq-free.md §10.3.
Wurk.configuration.server_middleware.add(Wurk::Metrics::History)

# Job status / progress / result tracking — a Wurk extra, opt-in per worker
# class via `sidekiq_options track: true`. Registered LAST of the built-ins so
# it is the innermost of them: the value it stores is `perform`'s own return
# value, and none of the middleware above may wrap or replace it on the way out
# first. Also registers a death handler, because whether a failed job retries or
# dies is decided in JobRetry, one frame outside any middleware.
require_relative 'wurk/middleware/status'

# Pro Fast API: Lua-backed Queue#delete_job / #delete_by_class plus
# SortedSet#scan { |JobRecord| … }. Mixed in via include/prepend on the
# existing data API classes so the surface is wire-compat with Sidekiq Pro.
# Spec: docs/target/sidekiq-pro.md §11.
require_relative 'wurk/api/fast'

# The machine-facing HTTP API's mount point (`mount Wurk::API`, `run
# Wurk::API`). Only the entry point loads here; the router, Rack::Request and
# the rest arrive on the first request, so a swarm that never serves HTTP pays
# nothing for the constant existing.
require_relative 'wurk/api'

# Sidekiq aliases load last — every Wurk::* constant they reference must be
# fully defined first. compat.rb only redefines names, it does not gate
# behavior, so trailing the load order is safe.
require_relative 'wurk/compat'

# Drop-in parity (#246): stock Sidekiq auto-loads its Rails integration when
# Rails is present (`lib/sidekiq.rb`: `require "sidekiq/rails" if
# defined?(Rails::Engine)`). Without the equivalent here, a host that follows
# the README/migration guide with a plain `gem "wurk"` (no `require:`) boots
# with the engine/railtie unloaded, so the `:wurk` / `:sidekiq` ActiveJob
# adapter constant is never defined and `config.active_job.queue_adapter =
# :wurk` raises NameError during the railtie phase. Loading the engine here
# (idempotent with an explicit `require "wurk/rails"`) closes that gap while
# keeping standalone, no-Rails boot fully Rails-free.
#
# Also gate on ActionDispatch::Routing::RouteSet: the engine's class body calls
# `isolate_namespace Wurk`, which under railties >= 8.1 eager-reads
# `ActionDispatch::Routing::RouteSet` to set the engine's @route_set_class.
# Ecosystem test helpers (sidekiq-cron, …) load `rails/engine/railties` for the
# railtie API alone — Rails::Engine is defined but ActionDispatch isn't — so a
# bare `defined?(Rails::Engine)` check would crash with `uninitialized constant
# Rails::Engine::Configuration::ActionDispatch` mid-`require "sidekiq"`. In a
# real Rails host both are loaded by `rails/all` before Bundler.require, so the
# stricter gate is invisible there.
require_relative 'wurk/rails' if defined?(Rails::Engine) && defined?(ActionDispatch::Routing::RouteSet)

# The gate above is evaluated exactly once, when this file is first required —
# which is too early for the standalone runners (#282). `exe/wurk` and
# `exe/wurkswarm` require "wurk" before Rails exists (the gate is false, nothing
# Rails-y loads), then boot the host app themselves via
# Wurk::CLI#boot_rails_application. By then "wurk" is in $LOADED_FEATURES, so the
# app's own `Bundler.require` is a no-op and the gate never gets a second look. A
# host that did exactly what the README says — `mount Wurk::Engine => "/wurk"` in
# config/routes.rb — then dies during boot with `uninitialized constant
# Wurk::Engine`, from the worker process only. Web processes are unaffected:
# there Bundler.require runs after railties, so the gate passes.
#
# `Wurk.const_missing` (defined in the class << self block above) closes that
# window without giving up the lean standalone boot: nothing loads until
# something actually asks for Wurk::Engine, and even then only when Rails is
# really present. It reuses the same two-part condition as the guard above, so
# the ecosystem carve-out (rails/engine/railties without ActionDispatch, per
# sidekiq-cron's test helper) still falls through to a plain NameError instead of
# crashing on `isolate_namespace`.
#
# It deliberately loads `wurk/engine`, not `wurk/rails`: the railtie's
# `config.after_initialize` is a *global* ActiveSupport load hook registered at
# require time, and routes are drawn before those hooks run — so dragging the
# railtie in there would fork a swarm inside a `wurkswarm` parent that is about
# to fork its own. The runner owns the swarm; the routes file only needs the
# constant. `defined?(Wurk::Engine)` stays nil until first use, which is what the
# "standalone stays Rails-free" tests assert.
