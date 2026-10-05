# frozen_string_literal: true

# Drop-in require path (see lib/sidekiq.rb): defines Sidekiq::CurrentAttributes
# (`persist`, `Save`, `Load`). Nothing is registered until `persist` is called,
# as upstream.
require 'wurk'
require 'wurk/middleware/current_attributes'
