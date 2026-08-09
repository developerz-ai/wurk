# frozen_string_literal: true

require 'digest'
require_relative '../keys'
require_relative 'problem'
require_relative 'response'
require_relative 'validation'

module Wurk
  module API
    # `Idempotency-Key` replay protection for the produce plane.
    #
    # A producer whose connection drops mid-`POST /jobs` cannot tell a lost
    # request from a lost response, so its only safe move is to send it again —
    # and without this, the retry is a second job. The header turns that retry
    # into a replay: the first request's response comes back verbatim and
    # nothing is enqueued twice.
    #
    # Entirely client-driven. No header means no key, no record and no round
    # trip, so a producer that does not need this pays nothing for it.
    module Idempotency
      HEADER = 'HTTP_IDEMPOTENCY_KEY'

      # The same shape a bearer token has to survive: printable ASCII, no
      # spaces. A key that loses a byte in transit would silently address a
      # different record, which is the one failure this module exists to
      # prevent.
      KEY_FORMAT = /\A[\x21-\x7e]{1,255}\z/

      # Marks a replayed response, so a client can tell "your job was enqueued"
      # from "your job was enqueued, earlier".
      REPLAY_HEADER = 'idempotency-replayed'

      # A record is `<status>\n<body digest>\n<body>`, and status `0` means a
      # claim still in flight. Line-oriented rather than JSON because it is
      # read back under contention: a truncated or hand-poisoned value has to
      # degrade to "still in progress", not to a parser exception on the
      # request path.
      PENDING = 0

      module_function

      # Wraps a state-changing handler. Without the header this is a bare call
      # through; with it, exactly one of the requests sharing a key runs the
      # handler and the rest replay its answer.
      #
      # @param raw_body [String] the bytes the response is pinned to, so the
      #   same key sent with a different body is a client bug, not a replay.
      def around(request, raw_body, config, &handler)
        key = presented(request)
        return handler.call unless key

        slot = slot_for(request, key)
        fingerprint = ::Digest::SHA256.hexdigest(raw_body)
        stored = claim(slot, fingerprint, config.api_idempotency_ttl)
        return replay(request, stored, fingerprint) if stored

        settle(slot, fingerprint, &handler)
      end

      def presented(request)
        key = request.get_header(HEADER)
        return nil if key.nil?
        return key if KEY_FORMAT.match?(key)

        raise Validation::Invalid, 'Idempotency-Key must be 1-255 printable ASCII characters with no spaces.'
      end

      # Scoped to the credential and to the route. The key is a string the
      # client chose: two producers that both sent `1` must not see each
      # other's jids, and the same key on `/jobs` and `/jobs/bulk` addresses two
      # different requests. Hashed rather than concatenated so the client's own
      # string never reaches Redis in the clear and every slot is one length.
      def slot_for(request, key)
        ::Wurk::Keys.idempotency(
          ::Digest::SHA256.hexdigest("#{request.principal.id}\n#{request.path_info}\n#{key}")
        )
      end

      # One round trip: reserve the key if it is free, and read what is there
      # either way. Deliberately not a MULTI — the SET already picked the
      # winner, and the GET only has to explain the loss.
      #
      # @return [String, nil] nil when this request owns the key; otherwise the
      #   record the owner left, or is still to leave. An empty string when the
      #   owner's record expired in between, which reads as "in flight" and is
      #   the safe answer: it never enqueues a second job.
      def claim(slot, fingerprint, ttl)
        reserved, existing = ::Wurk.redis do |conn|
          conn.pipelined do |pipe|
            pipe.call('SET', slot, encode(PENDING, fingerprint, ''), 'NX', 'EX', ttl)
            pipe.call('GET', slot)
          end
        end
        reserved ? nil : existing.to_s
      end

      # Only a success is worth replaying. A rejected body is a request the
      # client should be able to correct and send again under the same key, and
      # a raise is a request whose outcome nobody knows — both release the key
      # rather than pinning an answer to it.
      def settle(slot, fingerprint)
        response = yield
        response[0] < 300 ? record(slot, fingerprint, response) : release(slot)
        response
      rescue StandardError
        release(slot)
        raise
      end

      # KEEPTTL so the window is the first request's, not this write's, and XX
      # so a claim whose TTL lapsed mid-flight is not resurrected as a record
      # with no expiry at all.
      def record(slot, fingerprint, response)
        status, _headers, body = response
        ::Wurk.redis { |conn| conn.call('SET', slot, encode(status, fingerprint, body.join), 'XX', 'KEEPTTL') }
      end

      def release(slot)
        ::Wurk.redis { |conn| conn.call('DEL', slot) }
      end

      def replay(request, stored, fingerprint)
        record = decode(stored)
        return in_progress(request) unless record

        status, digest, body = record
        return reused(request) unless digest == fingerprint
        return in_progress(request) if status == PENDING

        [status, Response::HEADERS.merge(REPLAY_HEADER => 'true'), [body]]
      end

      def encode(status, digest, body) = "#{status}\n#{digest}\n#{body}"

      # @return [Array(Integer, String, String), nil] nil for a record that is
      #   gone or unreadable — the caller treats both as still in flight.
      def decode(stored)
        status, digest, body = stored.split("\n", 3)
        return nil if digest.nil? || digest.empty?

        [status.to_i, digest, body.to_s]
      end

      # 409 rather than 400: the request is well-formed, and what it collides
      # with is a fact about the server's state that the client can resolve by
      # rotating the key.
      def reused(request)
        Problem.render(
          Problem::IDEMPOTENCY_KEY_REUSED,
          status: 409,
          detail: 'This Idempotency-Key was already used for a different request body.',
          instance: request.path
        )
      end

      def in_progress(request)
        Problem.render(
          Problem::REQUEST_IN_PROGRESS,
          status: 409,
          detail: 'A request with this Idempotency-Key is still in flight.',
          instance: request.path,
          headers: { 'retry-after' => '1' }
        )
      end
    end
  end
end
