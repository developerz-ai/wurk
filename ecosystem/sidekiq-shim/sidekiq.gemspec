# frozen_string_literal: true

# Bundler-level Sidekiq substitution (#204). Third-party ecosystem gems
# declare `add_dependency "sidekiq"`; without this shim, bundling one of them
# installs REAL sidekiq next to wurk and `require "sidekiq"` loads a
# half-real/half-wurk hybrid (constant collisions, jobs running on sidekiq).
# This gem satisfies that dependency with wurk instead:
#
#   gem "wurk"
#   gem "sidekiq", github: "developerz-ai/wurk", glob: "ecosystem/sidekiq-shim/*.gemspec"
#
# Never published to rubygems.org (the name belongs to Sidekiq); it is only
# consumable via git/path sources, which is exactly the override mechanism
# bundler provides for this.

# Single source of truth: mirror the Sidekiq release wurk targets
# (Sidekiq::VERSION in lib/wurk/compat.rb) so ecosystem gems' version gates
# (`add_dependency "sidekiq", ">= 6.5"` etc.) resolve the same as upstream.
compat = File.read(File.expand_path('../../lib/wurk/compat.rb', __dir__))
sidekiq_version = compat[/VERSION\s*=\s*'([^']+)'/, 1] or raise 'Sidekiq::VERSION not found in lib/wurk/compat.rb'

Gem::Specification.new do |spec|
  spec.name        = 'sidekiq'
  spec.version     = sidekiq_version
  spec.authors     = ['developerz.ai']
  spec.email       = ['admin@developerz.ai']

  spec.summary     = 'Shim: satisfies a `sidekiq` gem dependency with wurk.'
  spec.description = 'Loads wurk when a gem depends on sidekiq. Git/path consumption only — never published.'
  spec.homepage    = 'https://github.com/developerz-ai/wurk'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 3.2.0'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files         = Dir['lib/**/*.rb', 'README.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'wurk'
end
