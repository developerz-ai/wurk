# frozen_string_literal: true

require_relative 'worker'

module Wurk
  # Sidekiq 7+ alias for Wurk::Worker. `include Wurk::Job` and
  # `include Sidekiq::Job` are the same surface.
  #
  # Instance-level `jid`, `_context`, `interrupted?`, and `logger` come
  # from Wurk::Worker. Class-level DSL (`sidekiq_options`, `perform_*`,
  # `set`, retry blocks) does too — Job is a pure alias module that
  # re-exposes Worker under the modern name.
  module Job
    # Raised mid-iteration when the run loop must yield — either a swarm
    # shutdown signal or a cooperative cancellation. The interrupt-handler
    # middleware catches it, re-pushes the job, and raises
    # `Wurk::JobRetry::Skip` so the retry layer skips error bookkeeping.
    # User code must not rescue this.
    #
    # Spec: docs/target/sidekiq-free.md §6.4.
    class Interrupted < RuntimeError; end

    def self.included(base)
      base.include(Wurk::Worker)
    end

    # Mirror the module-level test helpers so `Sidekiq::Job.jobs /
    # clear_all / drain_all` work the same as `Sidekiq::Worker.*`.
    def self.jobs       = Wurk::Worker.jobs
    def self.clear_all  = Wurk::Worker.clear_all
    def self.drain_all  = Wurk::Worker.drain_all
  end
end
