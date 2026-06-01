# frozen_string_literal: true

require_relative "lib/wurk/version"

Gem::Specification.new do |spec|
  spec.name        = "wurk"
  spec.version     = Wurk::VERSION
  spec.authors     = ["developerz.ai"]
  spec.email       = ["admin@developerz.ai"]

  spec.summary     = "100% drop-in replacement for Sidekiq + Sidekiq Pro + Sidekiq Enterprise. Free. Faster."
  spec.description = "Wire-compatible Ruby background job processor: same Redis schema, same job JSON, same Ruby DSL. Pro + Enterprise feature parity in the same gem, no license check. Fork-based real parallelism. Mountable Rails engine with a precompiled React dashboard."
  spec.homepage    = "https://github.com/developerz-ai/wurk"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["source_code_uri"]   = spec.homepage
  spec.metadata["documentation_uri"] = "#{spec.homepage}/tree/main/docs"
  spec.metadata["changelog_uri"]     = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]   = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Ship only what the gem needs at runtime: Ruby, the precompiled dashboard
  # (js/css/html + asset manifest), the engine's config, README, and LICENSE.
  # No images, no docs/, no CHANGELOG/CONTRIBUTING/SECURITY — those live on
  # GitHub (see the *_uri metadata above).
  spec.files = Dir[
    "lib/**/*.rb",
    "app/**/*.rb",
    "config/**/*",
    "exe/*",
    "vendor/assets/dashboard/**/*",
    "README.md",
    "LICENSE"
  ]

  spec.bindir      = "exe"
  spec.executables = ["wurk"]
  spec.require_paths = ["lib"]

  # Bounded ranges (not pessimistic `~>`) where a newer major is already in
  # use: connection_pool 3.x and rack 3.x (Rails 7.1+/8) must both be allowed,
  # so cap at the *next* untested major rather than the current one.
  spec.add_dependency "redis-client", "~> 0.22"
  spec.add_dependency "connection_pool", ">= 2.4", "< 4"
  spec.add_dependency "rack", ">= 2.2", "< 4"
  spec.add_dependency "concurrent-ruby", "~> 1.2"
end
