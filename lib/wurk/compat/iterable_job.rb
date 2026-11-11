# frozen_string_literal: true

# Autoload target of IterableJob's Sidekiq aliases (compat.rb).

module Sidekiq
  IterableJob      = Wurk::IterableJob
  IterableJobQuery = Wurk::IterableJobQuery
end
