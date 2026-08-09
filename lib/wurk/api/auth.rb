# frozen_string_literal: true

require 'digest'
require 'openssl'
require_relative 'problem'

module Wurk
  module API
    # Bearer-token authentication and scope checks for the machine-facing HTTP
    # API. Nothing behind /v1 answers without passing through here.
    #
    # Deliberately a separate plane from the dashboard's. That one is cookie-
    # authenticated and CSRF-guarded by Wurk::SameOriginGuard, which denies any
    # request that doesn't carry `Sec-Fetch-Site: same-origin` — a header the
    # browser sets and a Python or Go producer never sends. Reusing it would
    # mean either 403ing every legitimate machine client or relaxing the one
    # check that stops a cross-site page from driving a logged-in operator's
    # dashboard.
    module Auth
      # `admin` grants the other two. An operator token allowed to stop a
      # process but refused a queue listing would be a surprise, not a
      # safeguard.
      SCOPES = %i[enqueue read admin].freeze

      # Required scope for a route every authenticated client needs whatever it
      # was granted — the discovery document, which an enqueue-only producer
      # has to read to confirm the contract it is about to post to.
      ANY = :any

      ROUTE_SCOPES = (SCOPES + [ANY]).freeze

      # Under 20 characters the host almost certainly typed the token instead of
      # generating one (`SecureRandom.urlsafe_base64(16)` is 22). A guessable
      # token on this API is remote code selection, not just a data leak.
      MIN_TOKEN_LENGTH = 20

      # Printable ASCII, no spaces — what an Authorization header carries
      # intact. A token that loses a byte in transit fails as "wrong token",
      # the least debuggable 401 there is, so reject the shape up front.
      TOKEN_FORMAT = /\A[\x21-\x7e]+\z/

      # RFC 6750 §2.1. The scheme is case-insensitive (RFC 9110 §11.1); the
      # credential is not.
      BEARER = /\ABearer[ \t]+([\x21-\x7e]+)[ \t]*\z/i

      REALM = 'Bearer realm="wurk"'

      # What the request proved about itself: the scopes it was granted, and
      # nothing that could identify the secret it presented.
      Principal = Struct.new(:scopes) do
        def permits?(scope)
          scope == ANY || scopes.include?(scope) || scopes.include?(:admin)
        end
      end

      module_function

      # The gate the whole API hangs off. No token registered → the engine
      # never mounts the app, and an app mounted directly answers 404 rather
      # than advertising a surface with nothing behind it.
      def configured?(config)
        !config.api_tokens.empty?
      end

      # Validates a credential where it is declared, so a typo raises in the
      # initializer that wrote it instead of surfacing as a 401 in production.
      #
      # @return [Array(String, Array<Symbol>)] token value and granted scopes
      def credential!(token, scopes)
        value = token.to_s
        unless value.length >= MIN_TOKEN_LENGTH
          raise ArgumentError, "api_token must be at least #{MIN_TOKEN_LENGTH} characters"
        end
        raise ArgumentError, 'api_token must be printable ASCII with no spaces' unless TOKEN_FORMAT.match?(value)

        [value, granted!(scopes)]
      end

      def granted!(scopes)
        granted = Array(scopes).map { |scope| scope.to_s.to_sym }.uniq
        raise ArgumentError, 'api_token requires at least one scope' if granted.empty?

        unknown = granted - SCOPES
        unless unknown.empty?
          raise ArgumentError, "unknown api_token scope #{unknown.inspect}; valid scopes are #{SCOPES.inspect}"
        end

        granted.freeze
      end

      # @return [Principal, nil] nil when no credential was presented, or the
      #   one presented matches nothing registered.
      def authenticate(request, config)
        presented = bearer(request.get_header('HTTP_AUTHORIZATION'))
        return nil unless presented

        scopes = lookup(presented, config.api_tokens)
        scopes && Principal.new(scopes)
      end

      def bearer(header)
        match = BEARER.match(header.to_s)
        match && match[1]
      end

      # Walks every registered token with no early return on a hit, so the
      # clock can't tell a client where in the table its guess landed — or
      # whether it landed at all. Both sides are digested first: OpenSSL's
      # compare demands equal lengths, and the bytesize pre-check the obvious
      # implementation reaches for (Rack::Utils.secure_compare does exactly
      # that) answers "how long is the real token" to anyone who can time this.
      def lookup(presented, tokens)
        digest = ::Digest::SHA256.digest(presented)
        found = nil
        tokens.each do |token, scopes|
          found = scopes if OpenSSL.fixed_length_secure_compare(digest, ::Digest::SHA256.digest(token))
        end
        found
      end

      # RFC 6750 §3. The challenge names `invalid_token` only when the client
      # actually presented one — telling a client that sent no credential that
      # its credential was rejected sends it hunting for the wrong bug.
      def unauthorized(request)
        presented = request.get_header('HTTP_AUTHORIZATION')
        Problem.render(
          Problem::UNAUTHORIZED,
          status: 401,
          detail: presented ? 'The bearer token presented is not valid.' : 'A bearer token is required.',
          instance: request.path,
          headers: { 'www-authenticate' => presented ? %(#{REALM}, error="invalid_token") : REALM }
        )
      end

      # 403, not a 404 hiding the route: the client already authenticated, so
      # concealing the address buys nothing and costs it the one fact it needs
      # — which scope to ask its operator for.
      def forbidden(request, scope)
        Problem.render(
          Problem::INSUFFICIENT_SCOPE,
          status: 403,
          detail: "This token is not granted the #{scope} scope.",
          instance: request.path,
          headers: { 'www-authenticate' => %(#{REALM}, error="insufficient_scope", scope="#{scope}") },
          required_scope: scope
        )
      end
    end
  end
end
