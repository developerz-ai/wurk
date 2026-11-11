# frozen_string_literal: true

# Drop-in require entrypoint (#204): `require "sidekiq"` loads Wurk and its
# Sidekiq::* alias layer (lib/wurk/compat.rb), so code and third-party gems
# written against Sidekiq load Wurk without changing a single require. The
# sibling files under lib/sidekiq/ cover the documented `require "sidekiq/…"`
# sub-paths the ecosystem uses. "wurk" loads the client tier and autoloads the
# rest (Wurk::LazyLoader); a sub-path whose surface is lazy loads it, so
# `require "sidekiq/web"` defines Sidekiq::Web as it does upstream.
#
# Bundler-level substitution (a gem's `add_dependency "sidekiq"`) is handled
# by the companion shim gem in ecosystem/sidekiq-shim/.
require 'wurk'

# Upstream sidekiq.rb does exactly this: a Rails host that Bundler.requires
# the gem gets the Rails integration without a separate require.
require_relative 'sidekiq/rails' if defined?(Rails::Engine)
