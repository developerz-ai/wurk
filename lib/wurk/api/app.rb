# frozen_string_literal: true

require 'json'
require 'rack'
require_relative '../version'
require_relative 'auth'
require_relative 'problem'
require_relative 'request'
require_relative 'router'

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
      API_VERSION = 'v1'
      VERSION_PREFIX = "/#{API_VERSION}".freeze
      SUPPORTED_VERSIONS = [API_VERSION].freeze

      JSON_HEADERS = { 'content-type' => 'application/json', 'x-content-type-options' => 'nosniff' }.freeze

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
        response = handle(request)
        # HEAD is routed as GET, so the handler built a body it must not send.
        request.head? ? [response[0], response[1], []] : response
      end

      private

      def config
        @config || ::Wurk.configuration
      end

      # Later slices hang their own tables off this: jobs, queues, swarm.
      def draw(router)
        router.get('/', scope: Auth::ANY) { |request| root(request) }
      end

      # Authentication runs before the version gate and before routing, so an
      # unauthenticated prober can't enumerate which paths or versions exist
      # from the difference between a 404 and a 405.
      def handle(request)
        return not_found(request) unless Auth.configured?(config)

        principal = Auth.authenticate(request, config)
        return Auth.unauthorized(request) unless principal

        request.principal = principal
        route(request)
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
      # is talking to before it starts guessing paths.
      def root(request)
        json(200, api_version: API_VERSION, wurk_version: ::Wurk::VERSION, url: request.url_for(VERSION_PREFIX))
      end

      def versioned?(path)
        path == VERSION_PREFIX || path.start_with?("#{VERSION_PREFIX}/")
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

      def json(status, payload)
        [status, JSON_HEADERS.dup, [::JSON.generate(payload)]]
      end
    end
  end
end
