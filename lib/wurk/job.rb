# frozen_string_literal: true

require_relative 'worker'
require_relative 'worker/setter'

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

    # Per-call option carrier returned by `set(...)`. Sidekiq 7+ documents it
    # under the modern mixin name `Sidekiq::Job::Setter`; since
    # `Sidekiq::Job = Wurk::Job`, this rebind is what makes that constant
    # resolve (without it `Sidekiq::Job::Setter` raises NameError). Same class
    # as `Sidekiq::Worker::Setter`. Spec: docs/target/sidekiq-free.md §6.3.
    Setter = Wurk::Worker::Setter

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
