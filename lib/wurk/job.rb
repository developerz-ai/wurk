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
    def self.included(base)
      base.include(Wurk::Worker)
    end
  end
end
