# frozen_string_literal: true

# Autoload target of Flow's Sidekiq aliases (compat.rb).

module Sidekiq
  Flow    = Wurk::Flow
  FlowSet = Wurk::FlowSet
end
