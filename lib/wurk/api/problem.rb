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
      # The same distinction one addressable resource over: a well-formed bid
      # the `batches` set has never held, as opposed to a mistyped path.
      BATCH_NOT_FOUND = 'batch_not_found'
      # A well-formed identity that no live heartbeat answers to — the process
      # exited, or its beat lapsed and Redis reaped the row.
      PROCESS_NOT_FOUND = 'process_not_found'
      # The process is live and the caller may signal it, but this one cannot
      # be signalled at all: an embedded process shares its host application's
      # PID, so a TSTP or TERM aimed at it would hit the web server around it.
      PROCESS_NOT_SIGNALABLE = 'process_not_signalable'
      # Named for RFC 6750 §3.1 so the slug and the `error=` the 403 carries in
      # WWW-Authenticate are the same word.
      INSUFFICIENT_SCOPE = 'insufficient_scope'
      # Separate from `invalid_request` because the client's fix is different:
      # nothing about the request's shape is wrong, it is only too big, and the
      # `max_bytes` extension member says by how much.
      PAYLOAD_TOO_LARGE = 'payload_too_large'
      # An authorization verdict, like `insufficient_scope` — the credential is
      # valid and the body is well-formed, but this class is not one the HTTP
      # API may enqueue.
      CLASS_NOT_ALLOWED = 'class_not_allowed'
      # The two ways an `Idempotency-Key` collides. Reused means the same key
      # arrived with different bytes, which is a client bug it must fix by
      # rotating the key; in-progress means the first request holding it has
      # not answered yet, which it fixes by waiting.
      IDEMPOTENCY_KEY_REUSED = 'idempotency_key_reused'
      REQUEST_IN_PROGRESS = 'request_in_progress'

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
        JOB_NOT_FOUND => 'Job Not Found',
        BATCH_NOT_FOUND => 'Batch Not Found',
        PROCESS_NOT_FOUND => 'Process Not Found',
        PROCESS_NOT_SIGNALABLE => 'Process Not Signalable',
        PAYLOAD_TOO_LARGE => 'Payload Too Large',
        CLASS_NOT_ALLOWED => 'Class Not Allowed',
        IDEMPOTENCY_KEY_REUSED => 'Idempotency Key Reused',
        REQUEST_IN_PROGRESS => 'Request In Progress'
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

      # Renders a refusal that already knows which problem it is — the shape
      # Validation::Invalid carries. The mapping from a rejection to a status
      # code stays with the check that made it, so a new rejection never needs
      # a new arm in the route that surfaces it.
      def from(error, instance:)
        render(error.type, status: error.status, detail: error.message, instance: instance, **error.extra)
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
