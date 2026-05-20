# frozen_string_literal: true

# Uses Wurk::Encryption (Ent parity).
class EncryptedJob
  include Wurk::Worker

  def perform(*args); end
end
