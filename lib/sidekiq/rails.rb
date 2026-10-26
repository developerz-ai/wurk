# frozen_string_literal: true

# Drop-in require path (see lib/sidekiq.rb): `require "sidekiq/rails"` in a
# Sidekiq app loads the Rails integration. Sidekiq's is railtie-grade and
# needs only railties — ecosystem test helpers load it with `rails/railtie`
# alone, no ActionDispatch — so this maps to the railtie, NOT the dashboard
# engine (a wurk-native extra; `require "wurk/rails"` for that). Sidekiq::Web
# stays mountable as a plain Rack app either way, exactly like upstream.
# A first require without ActiveJob preloaded needs ActiveSupport's core
# extensions before rails/railtie. Requiring rails for that bootstrap would
# also load ActionDispatch, breaking the railtie-only integration boundary.
require 'wurk'
require 'active_support'
require 'active_support/core_ext'
require 'wurk/railtie'
