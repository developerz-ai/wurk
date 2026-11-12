# sidekiq → wurk shim gem

Satisfies a `sidekiq` gem dependency with [wurk](https://github.com/developerz-ai/wurk).

Ecosystem gems (sidekiq-cron, sidekiq-unique-jobs, …) declare
`add_dependency "sidekiq"`. Without this shim, bundling one of them installs
**real Sidekiq alongside wurk** and `require "sidekiq"` loads a broken hybrid.
With it, bundler resolves that dependency to wurk:

```ruby
# Gemfile
gem "wurk"
gem "sidekiq", github: "developerz-ai/wurk", tag: "v1.15.1", glob: "ecosystem/sidekiq-shim/*.gemspec"
gem "sidekiq-cron" # or any other ecosystem gem
```

Pin `tag:` to the wurk release in your bundle (tags are `v<wurk version>`).
The shim depends on exactly the wurk version it was cut with, so a floating
`main` checkout or a `bundle update` that moves only one of the two fails to
resolve instead of mixing versions.

The shim's own version mirrors the Sidekiq release wurk targets
(`Sidekiq::VERSION` in `lib/wurk/compat.rb`), so ecosystem gems' version
gates resolve exactly as they would upstream.

The `sidekiq` executable comes from wurk itself, so `bundle exec sidekiq -C config/sidekiq.yml`
works with or without this shim.

**Never published to rubygems.org** — the `sidekiq` name belongs to Sidekiq.
Git/path consumption only. This is the standard bundler mechanism for
substituting a dependency by name.

Used by wurk's own ecosystem-compat CI: `bin/rake test:ecosystem` runs real
ecosystem gems' test suites against wurk through this shim
(see `test/ecosystem/`).
