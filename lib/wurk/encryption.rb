# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'
require_relative 'middleware'

module Wurk
  # Sidekiq Enterprise encryption. AES-256-GCM over the **last** positional
  # argument of `perform`. Implemented as a client/server middleware pair —
  # client envelopes the last arg into a `{v, iv, ct, tag}` Hash, server
  # peels it back before invoking perform.
  #
  # Activation:
  #
  #   Sidekiq::Enterprise::Crypto.enable(active_version: 1) do |version|
  #     File.read("config/crypto/secret.#{Rails.env}.#{version}.key", mode: 'rb')
  #   end
  #
  # The block is the **only** key source: file, ENV, KMS — anything that maps
  # `Integer version → 32-byte binary key`. Wurk caches resolved keys per
  # version in-process; rotate by writing a new key file, bumping
  # `active_version`, and calling `enable` again.
  #
  # Per-worker opt-in:
  #
  #   class PrivateJob
  #     include Sidekiq::Job
  #     sidekiq_options encrypt: true
  #     def perform(public_arg, secret_bag); end
  #   end
  #
  # Wire format (per docs/target/sidekiq-ent.md §4.4): the last arg becomes
  # a plain JSON Hash `{"v"=>N, "iv"=>b64(iv), "ct"=>b64(ct), "tag"=>b64(tag)}`
  # — *not* a base64 blob of a binary envelope — so the args array stays
  # valid JSON for inspectors that don't know about encryption.
  #
  # Constraints:
  #   * `perform` must take ≥ 2 positional args. Pass `nil` first if no
  #     cleartext payload exists.
  #   * Only the last positional argument is encrypted. All earlier args
  #     remain plaintext.
  #   * Incompatible with Wurk::Unique (each ciphertext differs → digest
  #     defeats the lock). Documented invariant.
  #   * Web UI redacts the last arg when `encrypt: true` is set on the job.
  #
  # Spec: docs/target/sidekiq-ent.md §4.
  module Encryption
    CIPHER_NAME = 'aes-256-gcm'
    KEY_BYTES = 32
    IV_BYTES = 12 # GCM standard: 96-bit IV.
    TAG_BYTES = 16
    ENVELOPE_MARKER = '__wurk_enc__'

    class Error < StandardError; end
    class KeyMissingError < Error; end

    class << self
      attr_reader :active_version

      def enabled?
        @enabled == true
      end

      # Install crypto with a key resolver. `active_version` is the version
      # used to *encrypt* new pushes; the resolver block must still return
      # keys for any older in-flight versions so they decrypt.
      #
      # Idempotent: re-calling rebinds the resolver and rebuilds the cache.
      # Middleware is installed at most once per chain.
      def enable(active_version:, &resolver) # rubocop:disable Naming/PredicateMethod
        raise ArgumentError, 'active_version is required' unless active_version
        raise ArgumentError, 'block returning the key bytes is required' unless resolver

        @active_version = Integer(active_version)
        @resolver = resolver
        @key_cache = {}
        @enabled = true
        register_middleware!
        true
      end

      # Test helper — not part of the public Sidekiq surface.
      def disable!
        @enabled = false
        @active_version = nil
        @resolver = nil
        @key_cache = nil
        nil
      end

      # Resolve and cache the 32-byte key for `version`. Re-raises with a
      # Wurk-specific exception when the resolver returns nothing usable so
      # callers don't have to detect "nil from block" themselves.
      def key_for(version)
        raise Error, 'Wurk::Encryption not enabled' unless enabled?

        @key_cache ||= {}
        @key_cache[version] ||= validate_key!(version, @resolver.call(version))
      end

      # Encrypt `value` (any JSON-serializable Ruby value) under
      # `active_version`. Returns a Hash literal — JSON-friendly, so the
      # job payload stays inspectable.
      def encrypt(value)
        version = @active_version
        key = key_for(version)
        iv = ::OpenSSL::Random.random_bytes(IV_BYTES)
        cipher = ::OpenSSL::Cipher.new(CIPHER_NAME).encrypt
        cipher.key = key
        cipher.iv = iv
        ct = cipher.update(::JSON.dump(value)) + cipher.final
        tag = cipher.auth_tag(TAG_BYTES)

        {
          ENVELOPE_MARKER => true,
          'v' => version,
          'iv' => ::Base64.strict_encode64(iv),
          'ct' => ::Base64.strict_encode64(ct),
          'tag' => ::Base64.strict_encode64(tag)
        }
      end

      # Decrypt the envelope produced by `encrypt`. Raises
      # `OpenSSL::Cipher::CipherError` on tag mismatch (bad key / tamper)
      # — server middleware lets it bubble so the failure flows through
      # the retry/dead pipeline per §4.6.
      def decrypt(envelope)
        version = Integer(envelope['v'])
        cipher = build_decrypt_cipher(envelope, key_for(version))
        plain = cipher.update(::Base64.strict_decode64(envelope['ct'])) + cipher.final
        ::JSON.parse(plain, quirks_mode: true)
      end

      # @return [Boolean] true if `value` looks like a Wurk crypto envelope.
      # Used by both server middleware and the Web UI redactor — single
      # source of truth so the two cannot drift.
      def envelope?(value)
        value.is_a?(::Hash) && value[ENVELOPE_MARKER] == true &&
          value.key?('v') && value.key?('iv') && value.key?('ct') && value.key?('tag')
      end

      # Web UI display helper (§4.7). Given a job hash, returns the args
      # array with the last element replaced by the literal `"<encrypted>"`
      # when the job opted in. Cleartext preceding args are untouched so
      # operators can still triage on user_id / object_id / etc.
      def redact_args(job)
        args = job['args'] || job[:args] || []
        return args unless job['encrypt'] || job[:encrypt]
        return args if args.empty?

        args[0..-2] + ['<encrypted>']
      end

      private

      def build_decrypt_cipher(envelope, key)
        cipher = ::OpenSSL::Cipher.new(CIPHER_NAME).decrypt
        cipher.key = key
        cipher.iv = ::Base64.strict_decode64(envelope['iv'])
        cipher.auth_tag = ::Base64.strict_decode64(envelope['tag'])
        cipher
      end

      def validate_key!(version, bytes)
        raise KeyMissingError, "key resolver returned nil for version #{version}" if bytes.nil?

        bytes = bytes.dup.force_encoding(::Encoding::ASCII_8BIT)
        unless bytes.bytesize == KEY_BYTES
          raise Error, "key for version #{version} must be #{KEY_BYTES} bytes, got #{bytes.bytesize}"
        end

        bytes
      end

      def register_middleware!
        Wurk.configuration.client_middleware.add(ClientMiddleware) \
          unless Wurk.configuration.client_middleware.exists?(ClientMiddleware)
        Wurk.configuration.server_middleware.add(ServerMiddleware) \
          unless Wurk.configuration.server_middleware.exists?(ServerMiddleware)
      end
    end

    # Client middleware — envelopes the **last** positional argument when
    # the job opts in via `sidekiq_options encrypt: true`. Skips silently
    # when crypto is disabled, the job didn't opt in, or `args` is empty
    # (per §4.3, an opt-in worker with empty args is a user bug, but we
    # don't enqueue garbage — let perform raise ArgumentError if it cares).
    class ClientMiddleware
      include Wurk::Middleware::ClientMiddleware

      def call(_worker, job, _queue, _redis_pool)
        return yield unless Wurk::Encryption.enabled? && job['encrypt']

        args = job['args']
        if args.is_a?(::Array) && !args.empty? && !Wurk::Encryption.envelope?(args.last)
          job['args'] = args[0..-2] + [Wurk::Encryption.encrypt(args.last)]
        end
        yield
      end
    end

    # Server middleware — peels the envelope before perform runs. Decrypt
    # failures (bad tag, missing version) raise
    # `OpenSSL::Cipher::CipherError`; we let it bubble so the standard
    # retry/dead pipeline handles it. Plaintext args remain visible for
    # triage per §4.6.
    class ServerMiddleware
      include Wurk::Middleware::ServerMiddleware

      def call(_worker, job, _queue)
        return yield unless Wurk::Encryption.enabled? && job['encrypt']

        args = job['args']
        if args.is_a?(::Array) && !args.empty? && Wurk::Encryption.envelope?(args.last)
          job['args'] = args[0..-2] + [Wurk::Encryption.decrypt(args.last)]
        end
        yield
      end
    end
  end
end
