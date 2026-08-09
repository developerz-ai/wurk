# frozen_string_literal: true

require 'rack'

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
    class Router
      Route = Struct.new(:verb, :segments, :handler, keyword_init: true)
      # `handler` nil means nothing matched the path; `allowed` then carries the
      # verbs registered for a path that *did* match, so the caller can answer
      # 405 with an Allow header instead of a misleading 404.
      Match = Struct.new(:handler, :params, :allowed, keyword_init: true)

      NO_PARAMS = {}.freeze

      def initialize
        @routes = []
      end

      def get(pattern, &handler) = add('GET', pattern, handler)
      def post(pattern, &handler) = add('POST', pattern, handler)
      def delete(pattern, &handler) = add('DELETE', pattern, handler)

      # HEAD is served by the GET route (RFC 9110 §9.3.2); the caller drops the
      # body.
      def match(verb, path)
        verb = 'GET' if verb == 'HEAD'
        segments = split(path).map { |seg| ::Rack::Utils.unescape_path(seg) }
        allowed = []
        @routes.each do |route|
          params = bind(route.segments, segments)
          next unless params
          return Match.new(handler: route.handler, params: params, allowed: nil) if route.verb == verb

          allowed << route.verb
        end
        Match.new(handler: nil, params: NO_PARAMS, allowed: allowed.uniq)
      end

      private

      def add(verb, pattern, handler)
        @routes << Route.new(verb: verb, segments: split(pattern), handler: handler)
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
