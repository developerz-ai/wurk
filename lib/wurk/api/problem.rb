# frozen_string_literal: true

require 'json'

module Wurk
  module API
    # Error bodies for the HTTP API, shaped like RFC 9457 problem documents.
    #
    # One deliberate divergence from the RFC: `type` is a bare stable slug
    # ('not_found'), not a URI. A URI would either hardcode a docs host that can
    # move or emit a mount-relative path the client can't dereference, and the
    # slug is the part a client actually branches on. `/v1` makes these slugs a
    # contract: adding one is fine, renaming one is a breaking change.
    module Problem
      CONTENT_TYPE = 'application/problem+json'

      NOT_FOUND = 'not_found'
      METHOD_NOT_ALLOWED = 'method_not_allowed'
      UNSUPPORTED_API_VERSION = 'unsupported_api_version'
      INTERNAL_ERROR = 'internal_error'

      # Every slug needs a human title; `fetch` below turns a missing one into a
      # loud failure in the test suite rather than a half-formed error body.
      TITLES = {
        NOT_FOUND => 'Not Found',
        METHOD_NOT_ALLOWED => 'Method Not Allowed',
        UNSUPPORTED_API_VERSION => 'Unsupported API Version',
        INTERNAL_ERROR => 'Internal Server Error'
      }.freeze

      module_function

      # `extra` keywords become extension members (RFC 9457 §3.2), e.g.
      # `supported_versions:`. Returns a Rack response triple.
      def render(type, status:, detail:, instance:, headers: nil, **extra)
        body = {
          type: type, title: TITLES.fetch(type), status: status, detail: detail, instance: instance
        }
        body.merge!(extra)
        [status, response_headers(headers), [::JSON.generate(body)]]
      end

      # nosniff so a browser pointed at an error can never be talked into
      # rendering the reflected request path as anything but data.
      def response_headers(extra)
        headers = { 'content-type' => CONTENT_TYPE, 'x-content-type-options' => 'nosniff' }
        extra ? headers.merge(extra) : headers
      end
    end
  end
end
