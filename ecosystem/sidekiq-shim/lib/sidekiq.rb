# frozen_string_literal: true

# The whole gem: `require "sidekiq"` → wurk. The full family of
# `require "sidekiq/…"` sub-paths is shipped by wurk itself (lib/sidekiq/),
# so this file only needs to exist for the case where this shim's load path
# is consulted before wurk's. Mirrors wurk's lib/sidekiq.rb, including
# upstream sidekiq.rb's implicit Rails-integration load.
require 'wurk'
require 'sidekiq/rails' if defined?(Rails::Engine)
