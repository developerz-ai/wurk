# frozen_string_literal: true

# Drop-in require shim for Sidekiq Pro's documented statsd setup:
#
#   require "sidekiq/middleware/server/statsd"
#   chain.add Sidekiq::Middleware::Server::Statsd
#
# The constant itself is defined by Wurk (lib/wurk/metrics/statsd.rb, aliased as
# Wurk::Middleware::Server::Statsd → Sidekiq::Middleware::Server::Statsd via the
# compat layer). This file just ensures Wurk is loaded so the verbatim Pro
# `require` resolves instead of raising LoadError. Spec: docs/target/sidekiq-pro.md §9.1.
require 'wurk' unless defined?(::Sidekiq::Middleware::Server::Statsd)
