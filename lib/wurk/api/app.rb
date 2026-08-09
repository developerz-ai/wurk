# frozen_string_literal: true

require 'rack'
require_relative '../api'
require_relative '../version'
require_relative 'auth'
require_relative 'jobs'
require_relative 'problem'
require_relative 'queues'
require_relative 'read_only'
require_relative 'request'
require_relative 'response'
require_relative 'router'
require_relative 'swarm'
require_relative 'throttle'

module Wurk
  module API
    # The machine-facing HTTP API. Plain Rack under lib/, with no reference to
    # Rails or the engine, so one implementation serves all three mounts:
    # engine-nested (`<mount>/api/v1`), separately mounted
    # (`mount Wurk::API => '/wurk-api'`), and standalone (`run Wurk::API`).
    #
    # Nothing here hardcodes '/wurk'. Every URL the API emits is built from
    # SCRIPT_NAME (Request#url_for) — the same mount-agnostic rule the SPA shell
    # follows in dashboard_controller.rb.
    class App
      # `config` is read on every request rather than captured, so a token
      # registered after the first request still takes effect. Injectable
      # because a test must be able to hand this app its own token table
      # instead of mutating the process-wide one.
      def initialize(config: nil)
        @config = config
        @router = Router.new
        draw(@router)
      end

      def call(env)
        request = Request.new(env)
        # Stamped once, before anything reads it, so every handler sees the
        # same config the auth gate did — including a test's injected one.
        request.config = config
        response = handle(request)
        # HEAD is routed as GET, so the handler built a body it must not send.
        request.head? ? [response[0], response[1], []] : response
      end

      private

      def config
        @config || ::Wurk.configuration
      end

      # One table per plane, each owning its own routes and handlers. Swarm
      # joins Jobs and Queues here.
      def draw(router)
        router.get('/', scope: Auth::ANY) { |request| root(request) }
        Jobs.draw(router)
        Queues.draw(router)
        Swarm.draw(router)
      end

      # Authentication runs before the version gate and before routing, so an
      # unauthenticated prober can't enumerate which paths or versions exist
      # from the difference between a 404 and a 405.
      #
      # Then two refusals that are true of the whole deployment rather than of
      # any one route, in cost order. Read-only is a fact this process already
      # holds, so it answers without touching Redis. The throttle needs a
      # credential to charge, which is why it cannot run before authentication —
      # and it charges every authenticated request, routed or not: a client
      # walking paths that don't exist is exactly the traffic a ceiling is for.
      def handle(request)
        config = request.config
        return not_found(request) unless Auth.configured?(config)

        principal = Auth.authenticate(request, config)
        return Auth.unauthorized(request) unless principal

        request.principal = principal
        refusal = ReadOnly.refuse(request) || Throttle.refuse(request)
        refusal || route(request)
      rescue StandardError => e
        internal_error(request, e)
      end

      def route(request)
        path = request.path_info.to_s
        return unsupported_version(request) unless versioned?(path)

        dispatch(request, path.delete_prefix(VERSION_PREFIX))
      end

      def dispatch(request, path)
        match = @router.match(request.request_method, path)
        return route_miss(request, match) unless match.handler
        return Auth.forbidden(request, match.scope) unless request.principal.permits?(match.scope)

        request.path_params = match.params
        match.handler.call(request)
      end

      # The document a client hits to confirm which mount and which contract it
      # is talking to before it starts guessing paths. It carries the two
      # deployment-wide refusals as well: both are things a producer would
      # otherwise only learn by having a write refused, and a client that can
      # read "this one is frozen" at startup fails in its own logs instead of
      # halfway through a batch.
      def root(request)
        Response.json(
          200,
          api_version: API_VERSION, wurk_version: ::Wurk::VERSION, url: request.url_for(VERSION_PREFIX),
          read_only: ReadOnly.enabled?(request), rate_limit: rate_limit(request.config)
        )
      end

      # nil, not an object with nil members: "there is no ceiling here" and
      # "there is one, of unknown size" are different answers.
      def rate_limit(config)
        limit = config.api_rate_limit
        return nil unless limit

        { limit: limit, interval_seconds: Throttle.interval_seconds(config.api_rate_limit_interval) }
      end

      def versioned?(path)
        path == VERSION_PREFIX || path.start_with?(NESTED_PREFIX)
      end

      def route_miss(request, match)
        return not_found(request) if match.allowed.empty?

        Problem.render(
          Problem::METHOD_NOT_ALLOWED,
          status: 405,
          detail: "#{request.request_method} is not allowed on #{request.path_info}.",
          instance: request.path,
          headers: { 'allow' => allow_header(match.allowed) }
        )
      end

      # A path that answers GET answers HEAD too, so advertise both.
      def allow_header(verbs)
        verbs = verbs.dup
        verbs << 'HEAD' if verbs.include?('GET')
        verbs.join(', ')
      end

      def not_found(request)
        Problem.render(
          Problem::NOT_FOUND,
          status: 404,
          detail: "No route matches #{request.request_method} #{request.path_info}.",
          instance: request.path
        )
      end

      # 404 rather than 400: an unknown version is an address that does not
      # exist, and the client's own request was well-formed.
      def unsupported_version(request)
        Problem.render(
          Problem::UNSUPPORTED_API_VERSION,
          status: 404,
          detail: "The Wurk HTTP API is served under #{VERSION_PREFIX}.",
          instance: request.path,
          supported_versions: SUPPORTED_VERSIONS
        )
      end

      # The exception details stay in the log. A machine client gets a stable
      # slug it can retry on, never a backtrace naming host internals.
      def internal_error(request, error)
        ::Wurk.logger.error { "Wurk::API #{request.request_method} #{request.path}: #{error.class}: #{error.message}" }
        ::Wurk.logger.debug { Array(error.backtrace).join("\n") }
        Problem.render(
          Problem::INTERNAL_ERROR,
          status: 500,
          detail: 'The request could not be completed.',
          instance: request.path
        )
      end
    end
  end
end
