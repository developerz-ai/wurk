# Rails Engine

Wurk is packaged as a mountable Rails engine. That gives us:

- A dashboard mount point with no host-app boilerplate.
- Asset path for the precompiled SolidJS SPA.
- A railtie hook for post-init forking.
- Generators for the install flow.

## Mount point is the host's choice

Wurk does **not** force a fixed mount path. The host app mounts the engine wherever it wants — `/wurk`, `/sidekiq`, `/admin/jobs`, `/internal/queues`, anything. The dashboard SPA uses relative URLs and the engine routes are nested, so any mount path works.

The install generator suggests `/wurk` as a default but the user is free to change the mount line. A Sidekiq-compatible alias at `/sidekiq` is supported simply by mounting twice.

## Top-level layout

- `lib/wurk.rb` — standalone entry point.
- `lib/wurk/` — core modules: worker, client, swarm, manager, fetcher, processor, middleware, batch, limiter, cron, unique, encryption, redis pool, compat aliases.
- `lib/wurk/engine.rb` — Rails::Engine subclass.
- `lib/wurk/railtie.rb` — boot hooks.
- `lib/wurk/rails.rb` — the one-line require.
- `app/` — engine views, controllers, asset sources for the dashboard.
- `config/routes.rb` — engine routes (nested under whatever mount the host chooses).
- `config/locales/` — bundled i18n translations.
- `bin/wurk` and `exe/wurk` — standalone runner.
- `test/` — Minitest, parallel.
- `test/dummy/` — embedded Rails app for engine tests (see 10-dummy-app.md).
- `vendor/assets/` — precompiled SPA bundle baked into the gem at build time (see 09-precompiled-assets.md).
- `wurk.gemspec`, `Gemfile`, `Rakefile`.

## Two entry points

- Standalone Ruby uses `require "wurk"` plus a small configure block.
- Rails apps use `require "wurk/rails"`. This loads Wurk, defines the engine, and registers the railtie that forks workers after `after_initialize`.

## Install generator

A `wurk:install` generator writes a config initializer with sensible defaults and adds a commented-out mount line to the host app's routes file. The user uncomments it at whatever path they prefer.

## Disabling auto-fork

When the host runs as a separate worker deploy (no embedded mode wanted), set `WURK_DISABLED=1` in the env and run the standalone binary instead. The railtie skips the swarm boot when this var is set, when Rails is in console mode, or when the test environment is active.
