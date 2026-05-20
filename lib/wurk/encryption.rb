# frozen_string_literal: true

module Wurk
  # Sidekiq Enterprise encryption. AES-256-GCM with key rotation.
  # Implemented as a middleware pair encrypting/decrypting job args.
  module Encryption
    class ClientMiddleware; end
    class ServerMiddleware; end

    class << self
      def keys; end
      def rotate!(new_key); end
    end
  end
end
