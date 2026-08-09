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
    end
  end
end
