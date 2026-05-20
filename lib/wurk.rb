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
require_relative 'wurk/capsule'
require_relative 'wurk/configuration'
require_relative 'wurk/job_util'
require_relative 'wurk/client'
require_relative 'wurk/client/buffered'
require_relative 'wurk/worker'
require_relative 'wurk/worker/setter'
require_relative 'wurk/job'
require_relative 'wurk/iterable_job'
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
require_relative 'wurk/swarm'
require_relative 'wurk/topology'
require_relative 'wurk/lua'
require_relative 'wurk/batch'
require_relative 'wurk/batch/status'
require_relative 'wurk/limiter'
require_relative 'wurk/cron'
require_relative 'wurk/leader'
require_relative 'wurk/unique'
require_relative 'wurk/encryption'
require_relative 'wurk/metrics'
require_relative 'wurk/metrics/statsd'
require_relative 'wurk/metrics/history'
require_relative 'wurk/compat'

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

    def configuration
      @configuration ||= Configuration.new
    end

    def redis(&)
      (Thread.current[:wurk_capsule] || configuration.default_capsule).redis_pool.with(&)
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
