# Precompiled Assets

The dashboard is a React SPA. Building it requires bun, Vite. **Consumers of the gem must never need any of that.**

## Policy

Assets are built once, at gem release time, and shipped inside the gem. Installing wurk into a Rails app pulls in the prebuilt bundle. No bun install, no asset pipeline integration on the consumer side, no Sprockets configuration needed.

## What ships in the gem

- A minified production bundle of the React SPA (one JS file, one CSS file, plus any static images and fonts).
- Source maps, optional, gated by a build flag.
- A simple manifest mapping logical names to digested filenames.

The gem's load path includes the precompiled bundle directory. The engine serves these files as static assets under the dashboard mount point.

## Build at release time

The release process (a Rake task or GitHub Action) does:

1. Install JS deps in the gem's frontend source directory (`bun install`).
2. Run Vite production build (SCSS + TS compiled to one CSS + JS bundle).
3. Copy the bundle output into the gem's vendored asset directory.
4. Run gem build.
5. Push the gem to RubyGems.

The frontend source lives in the repo but is gitignored from the gem's file list — only the built artifacts ship.

## Why this matters

- Dev experience: rails new app + bundle add wurk + done. No node version dance.
- Deploy experience: production containers don't need Node installed.
- Speed: zero asset compilation cost on consumer side. The dashboard loads as static files from disk.
- Reproducibility: the bundle that ships is the exact bundle we tested.

## Local development override

When working on the dashboard inside the wurk repo, an env var switches the engine to serve from a Vite dev server (with hot reload) instead of the prebuilt bundle. This is only for wurk contributors — consumers never use it.

## Versioning

The bundle's manifest includes a version string tied to the gem version. The engine refuses to start if the manifest is missing or its version doesn't match. This catches packaging mistakes early.
