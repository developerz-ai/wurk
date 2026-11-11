# frozen_string_literal: true

# Bundler-level Sidekiq substitution (#204). Third-party ecosystem gems
# declare `add_dependency "sidekiq"`; without this shim, bundling one of them
# installs REAL sidekiq next to wurk and `require "sidekiq"` loads a
# half-real/half-wurk hybrid (constant collisions, jobs running on sidekiq).
# This gem satisfies that dependency with wurk instead:
#
#   gem "wurk"
#   gem "sidekiq", github: "developerz-ai/wurk", tag: "v<wurk version>", glob: "ecosystem/sidekiq-shim/*.gemspec"
#
# Never published to rubygems.org (the name belongs to Sidekiq); it is only
# consumable via git/path sources, which is exactly the override mechanism
# bundler provides for this.

# Single source of truth: mirror the Sidekiq release wurk targets
# (Sidekiq::VERSION in lib/wurk/compat.rb) so ecosystem gems' version gates
# (`add_dependency "sidekiq", ">= 6.5"` etc.) resolve the same as upstream.
# Match either quote style: the literal's quotes are whatever rubocop's
# Style/StringLiterals currently enforces, and pinning one of them makes an
# autocorrect over there break every ecosystem harness over here.
compat = File.read(File.expand_path('../../lib/wurk/compat.rb', __dir__))
sidekiq_version = compat[/VERSION\s*=\s*['"]([^'"]+)['"]/, 1]
raise 'Sidekiq::VERSION not found in lib/wurk/compat.rb' unless sidekiq_version

# The shim is only correct beside the wurk it was cut with: an unpinned
# dependency lets `bundle update` move wurk while the git source stays put.
wurk_version = File.read(File.expand_path('../../lib/wurk/version.rb', __dir__))[/VERSION\s*=\s*['"]([^'"]+)['"]/, 1]
raise 'Wurk::VERSION not found in lib/wurk/version.rb' unless wurk_version

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

  # No executable: wurk itself ships `sidekiq`, and two gems in one bundle
  # that provide the same command fight over its binstub.
  spec.files         = Dir['lib/**/*.rb', 'README.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'wurk', "= #{wurk_version}"
end
