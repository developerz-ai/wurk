# frozen_string_literal: true

# Autoload target of `Sidekiq::Deploy` (compat.rb).

module Sidekiq
  Deploy = Wurk::Deploy
end
