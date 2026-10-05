# Dummy App

Standard Rails engine convention: a minimal Rails app embedded in the gem repo at `test/dummy/`. It exists for one purpose — testing the engine the way a host app would consume it.

## What's in it

A skeletal Rails app with:

- SQLite.
- ActiveJob configured with the Wurk adapter.
- `SimpleJob` for the engine tests, plus the `WURK_DEMO=1` workload (`app/jobs/demo/`, `app/workloads/demo/`) and a demo Web extension (`lib/demo_ext/`) that keep every dashboard page populated during local development.
- The Wurk engine mounted at `/wurk` in the dummy app's routes.
- A bare `application.rb` that requires `wurk/rails`.
- No host-app business logic. Nothing beyond what the tests need.

## How tests use it

Engine tests boot the dummy app, exercise the engine's mount point, hit the dashboard JSON endpoints, run real jobs through real forks, observe Redis side-effects.

- Controller and request tests run inside the dummy.
- Integration tests for embedded mode boot the dummy and let the railtie fork workers, then send jobs and assert completion.
- The dashboard SPA's tests load the precompiled assets through the dummy's mount point.

## Why a dummy app and not a host-app fixture

A dummy app gives us a real Rails::Application instance with a real boot lifecycle. Mocking that out lies about the integration. The whole point of the engine is to be embedded in Rails — the test must embed it in Rails.

## Conventions

- The dummy app is gitignored from the gem's file list — it doesn't ship to RubyGems.
- The dummy's Gemfile points to the parent gem via `gem "wurk", path: "../.."`.
- CI runs one Rails, the newest; there is no version matrix.
