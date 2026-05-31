# Releasing Wurk

Wurk follows [Semantic Versioning](https://semver.org/). The version of record is
`Wurk::VERSION` in `lib/wurk/version.rb`; the gemspec reads it directly.

The dashboard bundle under `vendor/assets/dashboard/` is **built, not committed**
(it's git-ignored). It must be freshly baked before the gem is packaged so the
precompiled SPA ships inside the gem — consumers never run Node.

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
   tags: it rebuilds the dashboard, runs `rake release:check`, then builds and
   publishes the gem to RubyGems via trusted publishing. RubyGems MFA is
   required (`rubygems_mfa_required` is set in the gemspec).

## What `rake release:check` validates

| Check | Detail |
|---|---|
| **Dashboard bundle present** | `vendor/assets/dashboard/index.html` plus a non-empty `assets/*.js` exist. Run `rake frontend:build` if missing. |
| **Version ↔ CHANGELOG** | `CHANGELOG.md` contains a `## [<Wurk::VERSION>]` section header. |
| **Clean tree** | `git status --porcelain` is empty, ignoring `vendor/assets/` (built output). |
| **Tests green** | `rake test` (unit + integration + engine) passes. |

The same task runs in CI on the tagged commit, so a release cannot publish unless
the gate passes there too.

## Local one-shot publish (maintainers)

`rake release:full` chains `frontend:build → build → push`. Prefer the
tag-driven CI flow above; use this only for an out-of-band manual push.
