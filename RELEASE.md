# Releasing Wurk

Wurk follows [Semantic Versioning](https://semver.org/). The version of record is
`Wurk::VERSION` in `lib/wurk/version.rb`; the gemspec reads it directly.

The dashboard bundle under `vendor/assets/dashboard/` is **built, not committed**
(it's git-ignored). It must be freshly baked before the gem is packaged so the
precompiled SPA ships inside the gem — consumers never run Node.

Publishing is fully automated via **RubyGems Trusted Publishing (OIDC)** — there
is no long-lived `GEM_HOST_API_KEY`. A `v*` tag push runs
`.github/workflows/release.yml`, which exchanges a GitHub Actions OIDC token for
a short-lived RubyGems credential and pushes the gem.

## One-time setup: register the trusted publisher

Before the first release, a rubygems.org owner registers this repo as a trusted
publisher (this is the only manual step, done once):

1. On rubygems.org → the `wurk` gem → **Settings → Trusted Publishers → Add**
   (for a brand-new gem, use **Create a pending trusted publisher** so the first
   OIDC push can create the gem).
2. Set:
   - **Repository**: `developerz-ai/wurk`
   - **Workflow filename**: `release.yml`
   - **Environment**: *(leave blank unless the job sets one)*

No secret is stored in GitHub; the `release` job's `permissions: id-token: write`
is what authorizes the exchange.

## Cutting a release

1. **Bump the version** in `lib/wurk/version.rb` (e.g. `1.0.0` → `1.1.0`).

2. **Update `CHANGELOG.md`.** Add a dated section whose header matches the new
   version exactly — `## [1.1.0] - YYYY-MM-DD` — with changes grouped under the
   standard headings: Runtime, Batches, Limiters, Periodic, Encryption,
   Dashboard, Compat. Update the compare/link footnotes at the bottom.

3. **Build the dashboard bundle:**
   ```bash
   bundle exec rake frontend:build
   ```

4. **Run the gate:**
   ```bash
   bundle exec rake release:check
   ```
   It must pass before you tag (see below for what it validates).

5. **Commit** the version + CHANGELOG bump on a branch, open a PR, and merge to
   `main` once green.

6. **Tag and push** the merge commit:
   ```bash
   git tag v1.1.0
   git push origin v1.1.0
   ```
   The `release` workflow (`.github/workflows/release.yml`) triggers on `v*`
   tags and runs, in order:
   1. Rebuild the dashboard SPA (`rake frontend:build`).
   2. Assert the bundle + `wurk-manifest.json` are present and non-empty.
   3. The full gate (`rake release:check`).
   4. `gem build wurk.gemspec`, then assert the dashboard bundle is **inside**
      the resulting `.gem` (`gem unpack` + check).
   5. Exchange the OIDC token (`rubygems/configure-trusted-publisher`) and
      `gem push` — no API-key secret.
   6. Create a GitHub Release with the matching `CHANGELOG.md` section as the
      body and the `.gem` attached.

### Prereleases (release candidates)

For an `rc`, set `Wurk::VERSION` to a Ruby prerelease (e.g. `1.0.0.pre.rc1`) and
tag `v1.0.0-rc1`. The workflow auto-marks the GitHub Release as a prerelease
(the tag contains `-`) and reuses the base version's CHANGELOG section
(`## [1.0.0]`). The GA push is then just `Wurk::VERSION = "1.0.0"` + tag `v1.0.0`.

## What `rake release:check` validates

| Check | Detail |
|---|---|
| **Dashboard bundle present** | `vendor/assets/dashboard/index.html` plus a non-empty `assets/*.js` exist. Run `rake frontend:build` if missing. |
| **Version ↔ CHANGELOG** | `CHANGELOG.md` contains a `## [<Wurk::VERSION>]` section header. |
| **Clean tree** | `git status --porcelain` is empty, ignoring `vendor/assets/` (built output). |
| **Tests green** | `rake test` (unit + integration + engine) passes. |

The same task runs in CI on the tagged commit, so a release cannot publish unless
the gate passes there too.

## Local one-shot publish (emergency only)

`rake release:full` chains `frontend:build → build → push`, but its `push` uses
`gem push` with a personal `GEM_HOST_API_KEY` — outside the OIDC flow. Prefer the
tag-driven CI release above; use this only for an out-of-band manual push when CI
is unavailable.
