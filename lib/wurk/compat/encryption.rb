# frozen_string_literal: true

# Autoload target of `Sidekiq::Encryption` (compat.rb).

module Sidekiq
  Encryption = Wurk::Encryption
end
