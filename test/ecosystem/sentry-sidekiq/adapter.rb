# frozen_string_literal: true

# Test-only: the gem's spec_helper reaches into Sidekiq's private @config ivar.
require 'sidekiq/cli'

Sidekiq.instance_variable_set(:@config, Sidekiq.default_configuration)
