# frozen_string_literal: true

# Autoload target of the profile store's Sidekiq aliases (compat.rb).

module Sidekiq
  ProfileSet    = Wurk::ProfileSet
  ProfileRecord = Wurk::ProfileRecord
end
