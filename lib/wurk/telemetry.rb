# frozen_string_literal: true

require_relative '../wurk'

# `opentelemetry-api` is deliberately NOT a gemspec dependency (see wurk.gemspec):
# a host that doesn't trace must not carry the gem, and one that does already has
# it — every OTel SDK, exporter and instrumentation gem depends on the API.
#
# The require sits at load rather than at a call site so the answer is settled
# once. It is wrapped because "not installed" is the normal case, not an error.
begin
  require 'opentelemetry-api'
rescue LoadError
  # No OTel in this app. Wurk::Telemetry.available? reports false and nothing
  # downstream registers; see the module doc below.
  nil
end

module Wurk
  # Distributed tracing over the Redis hop: a producer span on enqueue whose
  # W3C trace context rides the job hash, and a linked consumer span when a
  # worker picks the job up.
  #
  # This file is not loaded by `require "wurk"`. {Wurk::Configuration#telemetry=}
  # pulls it in, so an app that never opts in never requires `opentelemetry-api`
  # either — Wurk does not decide on a host's behalf when a third-party gem gets
  # loaded, and an app with the gem installed but tracing off keeps the exact
  # object graph, payload bytes and hot path it has today.
  #
  # Opt in from the server config:
  #
  #   Wurk.configure_server do |config|
  #     config.telemetry = true
  #   end
  #
  # Both halves must hold before anything registers: the gem has to be there
  # ({available?}) *and* the host has to have asked ({Wurk::Configuration#telemetry?}).
  # {enabled?} is that gate.
  #
  # There is no `Sidekiq::Telemetry` alias: upstream Sidekiq has no such
  # constant, so aliasing would invent a Sidekiq surface rather than mirror one
  # — same call as `Wurk::Status` (see lib/wurk/compat.rb).
  module Telemetry
    # Instrumentation scope stamped on every span this gem emits.
    INSTRUMENTATION_NAME = 'wurk'

    # The API the client/server middlewares call. A defined `::OpenTelemetry` is
    # not proof the gem is there — a host can own that constant itself, and an
    # `opentelemetry-api` old enough to predate these entry points would answer
    # the constant check too. Asking for the surface at install time turns
    # either case into "tracing stays off" rather than a NoMethodError on the
    # first job of a deploy.
    REQUIRED_API = %i[propagation tracer_provider].freeze

    class << self
      # @return [Boolean] whether opentelemetry-api is loaded and exposes
      #   {REQUIRED_API}.
      #
      # Not memoized. A host is free to require `opentelemetry` after this file
      # (an initializer ordering Wurk before its tracing setup), and a `false`
      # cached at load would disable tracing for the life of the process with
      # nothing to point at.
      def available?
        return false unless defined?(::OpenTelemetry)

        REQUIRED_API.all? { |method| ::OpenTelemetry.respond_to?(method) }
      end

      # The registration gate — the host flag first, deliberately: an app that
      # never opted in must not so much as resolve the OTel constant.
      #
      # @param config [Wurk::Configuration]
      # @return [Boolean]
      def enabled?(config = Wurk.configuration)
        config.telemetry? && available?
      end

      # Bring the middleware registrations in line with {enabled?}. Called by
      # {Wurk::Configuration#telemetry=}, so the chain follows the flag in both
      # directions: a host that turns tracing back off (a test, a capsule built
      # for a client-only process) must stop stamping payloads, not just stop
      # exporting.
      #
      # Idempotent — Chain#add and the insert helpers all drop any prior entry
      # for the same class first.
      #
      # @param config [Wurk::Configuration]
      def install!(config = Wurk.configuration)
        unless enabled?(config)
          config.client_middleware.remove(ClientMiddleware)
          return config.server_middleware.remove(ServerMiddleware)
        end

        config.client_middleware.add(ClientMiddleware)
        install_server(config.server_middleware)
      end

      # Memoized against the provider that produced it rather than once for the
      # process: `OpenTelemetry::SDK.configure` is routinely called *after* the
      # code that will emit spans is loaded, and `OpenTelemetry.tracer_provider=`
      # swaps the object — a tracer cached before that would silently export
      # nothing for the life of the process. The check costs one `equal?` per
      # enqueue and re-resolves whenever the provider actually changes.
      #
      # The pair is published in a single store so a concurrent reader sees
      # either the old provider with its own tracer or the new one with its own,
      # never a tracer attributed to the wrong provider.
      def tracer
        memo     = @tracer
        provider = ::OpenTelemetry.tracer_provider
        return memo[1] if memo && memo[0].equal?(provider)

        (@tracer = [provider, provider.tracer(INSTRUMENTATION_NAME, Wurk::VERSION)].freeze)[1]
      end

      private

      # As far out in the server chain as the consumer span can go while still
      # sitting *inside* `InterruptHandler` — see ServerMiddleware's note on why
      # that one middleware stays outside. `InterruptHandler` prepends itself
      # when `wurk.rb` loads, so on the process config it is always entry 0 and
      # this lands at 1; a bare `Wurk::Configuration` (a client-only capsule, a
      # test) has no chain to anchor against and takes the head instead.
      # `insert_after`'s own miss behaviour is the tail, which would be the
      # innermost position — the opposite of what this wants.
      def install_server(chain)
        anchor = Wurk::Middleware::InterruptHandler
        return chain.insert_after(anchor, ServerMiddleware) if chain.exists?(anchor)

        chain.prepend(ServerMiddleware)
      end
    end
  end
end

require_relative 'telemetry/client_middleware'
require_relative 'telemetry/server_middleware'
