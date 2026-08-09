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
      UNAUTHORIZED = 'unauthorized'
      INVALID_REQUEST = 'invalid_request'
      # Distinct from `not_found`, which means the API has no such route. A
      # client that asked to cancel a job needs to tell "you addressed nothing"
      # apart from "that job already ran".
      JOB_NOT_FOUND = 'job_not_found'
      # Named for RFC 6750 §3.1 so the slug and the `error=` the 403 carries in
      # WWW-Authenticate are the same word.
      INSUFFICIENT_SCOPE = 'insufficient_scope'

      # Every slug needs a human title; `fetch` below turns a missing one into a
      # loud failure in the test suite rather than a half-formed error body.
      TITLES = {
        NOT_FOUND => 'Not Found',
        METHOD_NOT_ALLOWED => 'Method Not Allowed',
        UNSUPPORTED_API_VERSION => 'Unsupported API Version',
        INTERNAL_ERROR => 'Internal Server Error',
        UNAUTHORIZED => 'Unauthorized',
        INSUFFICIENT_SCOPE => 'Insufficient Scope',
        INVALID_REQUEST => 'Invalid Request',
        JOB_NOT_FOUND => 'Job Not Found'
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
