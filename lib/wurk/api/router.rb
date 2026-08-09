# frozen_string_literal: true

require 'rack'
require_relative 'auth'

module Wurk
  module API
    # Path table for the HTTP API. Deliberately not ActionDispatch: the API has
    # to route in standalone mode, where Rails is never loaded (CLAUDE.md —
    # "standalone mode must run without loading the engine").
    #
    # Patterns are literal segments plus `:name` captures ('/jobs/:jid').
    # A capture never spans '/', so a queue named "a/b" has to arrive
    # percent-encoded — the same constraint `config/routes.rb` puts on the
    # dashboard's `:name`.
    #
    # Every route names the Auth scope its caller must hold. The router only
    # records it — App#dispatch enforces it — but the keyword is required, so
    # adding an endpoint without deciding who may call it is impossible rather
    # than merely discouraged. A new route can never default open.
    class Router
      Route = Struct.new(:verb, :segments, :scope, :handler, keyword_init: true)
      # `handler` nil means nothing matched the path; `allowed` then carries the
      # verbs registered for a path that *did* match, so the caller can answer
      # 405 with an Allow header instead of a misleading 404.
      Match = Struct.new(:handler, :params, :scope, :allowed, keyword_init: true)

      NO_PARAMS = {}.freeze

      def initialize
        @routes = []
      end

      def get(pattern, scope:, &handler) = add('GET', pattern, scope, handler)
      def post(pattern, scope:, &handler) = add('POST', pattern, scope, handler)
      def delete(pattern, scope:, &handler) = add('DELETE', pattern, scope, handler)

      # HEAD is served by the GET route (RFC 9110 §9.3.2); the caller drops the
      # body.
      def match(verb, path)
        verb = 'GET' if verb == 'HEAD'
        segments = split(path).map { |seg| ::Rack::Utils.unescape_path(seg) }
        allowed = []
        @routes.each do |route|
          params = bind(route.segments, segments)
          next unless params
          if route.verb == verb
            return Match.new(handler: route.handler, params: params, scope: route.scope, allowed: nil)
          end

          allowed << route.verb
        end
        Match.new(handler: nil, params: NO_PARAMS, scope: nil, allowed: allowed.uniq)
      end

      private

      # A misspelled scope would 403 the route forever; reject it at draw time,
      # which is boot, rather than letting it surface as a runtime denial.
      def add(verb, pattern, scope, handler)
        unless Auth::ROUTE_SCOPES.include?(scope)
          raise ArgumentError, "unknown route scope #{scope.inspect}; valid scopes are #{Auth::ROUTE_SCOPES.inspect}"
        end

        @routes << Route.new(verb: verb, segments: split(pattern), scope: scope, handler: handler)
        self
      end

      def split(path) = path.to_s.split('/').reject(&:empty?)

      # nil (no match) is a different answer from {} (matched, no captures) —
      # the caller branches on it, so don't collapse them.
      def bind(pattern, segments)
        return nil unless pattern.size == segments.size

        params = {}
        pattern.each_with_index do |seg, index|
          if seg.start_with?(':')
            params[seg[1..].to_sym] = segments[index]
          elsif seg != segments[index]
            return nil
          end
        end
        params
      end
    end
  end
end
