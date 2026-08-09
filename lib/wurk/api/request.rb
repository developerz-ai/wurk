# frozen_string_literal: true

require 'rack'

module Wurk
  module API
    # Rack::Request plus the three things every API handler needs: the segment
    # captures the router bound ('/jobs/:jid' → `path_params[:jid]`), the
    # authenticated principal, and mount-agnostic URL building.
    class Request < ::Rack::Request
      # Set by App once Auth has accepted the credential, so a handler can ask
      # what the caller was granted without re-reading the header. Never nil by
      # the time a handler runs — an unauthenticated request never reaches one.
      attr_accessor :principal

      # The configuration this app is answering from, stamped by App before
      # anything reads it. Injectable there for tests, so a handler that wants
      # a boundary cap or a token's grants must ask the request rather than
      # reaching for the process-wide singleton behind the app's back.
      attr_accessor :config

      attr_writer :path_params

      def path_params
        @path_params ||= {}
      end

      # Root-relative on purpose. The API answers under three different
      # prefixes (engine-nested, separately mounted, standalone) and usually
      # sits behind a proxy, so SCRIPT_NAME is the only prefix it can trust —
      # rebuilding an absolute URL out of Host/X-Forwarded-* would hand clients
      # links to an origin they never asked for.
      def url_for(path)
        "#{script_name.to_s.chomp('/')}#{path}"
      end

      # At most `limit` bytes off the request body, so a caller can refuse an
      # oversized one without ever holding it. Rack 3.1 made `rack.input`
      # optional and a stream already at EOF answers nil, so both come back as
      # an empty string: a bodyless request is a request, not a crash.
      def read_body(limit)
        body&.read(limit).to_s
      end
    end
  end
end
