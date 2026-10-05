# frozen_string_literal: true

# Drop-in require path (see lib/sidekiq.rb): opts into the locale-propagating
# Sidekiq::Middleware::I18n pair, exactly as upstream's file does on require.
require 'wurk'
require 'wurk/middleware/i18n'
