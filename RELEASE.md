# Releasing Wurk

Wurk follows [Semantic Versioning](https://semver.org/). The version of record is
`Wurk::VERSION` in `lib/wurk/version.rb`; the gemspec reads it directly.

The dashboard bundle under `vendor/assets/dashboard/` is **built, not committed**
(it's git-ignored). It must be freshly baked before the gem is packaged so the
precompiled SPA ships inside the gem — consumers never run Node.

Releases publish from CI via **RubyGems Trusted Publishing (OIDC)** — there is no
long-lived `GEM_HOST_API_KEY` secret anywhere. The release workflow exchanges
GitHub's short-lived OIDC token for a scoped RubyGems credential at push time.

## Cutting a release

1. **Bump the version** in `lib/wurk/version.rb` (e.g. `1.0.0` → `1.1.0`). For a
   prerelease use RubyGems' dot form: `1.0.0.rc1` (not `1.0.0-rc1`).

2. **Update `CHANGELOG.md`.** Add a dated section whose header matches the new
   version exactly — `## [1.1.0] - YYYY-MM-DD` — with changes grouped under the
   standard headings: Runtime, Batches, Limiters, Periodic, Encryption,
   Dashboard, Compat. The release workflow lifts this section verbatim into the
   GitHub Release notes (`bin/changelog-section`), so write it for readers.

3. **Build the dashboard bundle and run the gate locally:**
   ```bash
   bundle exec rake frontend:build
   bundle exec rake release:check
   bundle exec rake release:package   # builds the .gem, asserts the SPA is inside it
   ```

4. **Commit** the version + CHANGELOG bump on a branch, open a PR, and merge to
   `main` once green.

5. **Tag and push** the merge commit:
   ```bash
   git tag v1.1.0            # prerelease: git uses a hyphen — git tag v1.0.0-rc1
   git push origin v1.1.0
   ```
   The `release` workflow (`.github/workflows/release.yml`) triggers on `v*`
   tags and does the rest, end-to-end, with no human-held secret.

   > **Never tag ahead of step 4.** The tag must point at a commit whose
   > `Wurk::VERSION` already equals it. Tagging first is the one way to strand a
   > release — see below.

## If a release fails

`release:check` runs *inside* the tag-triggered workflow, so a tag pushed at a
commit that was never bumped fails the gate and publishes nothing — but the
maintainer agent writes the GitHub Release notes at tag time, independently. The
result is a tag and a **GitHub Release marked `Latest` with no gem behind it**,
while `gem install wurk` quietly keeps serving the previous version. This is what
happened to the first `v1.5.0` (tagged at `13b64e8`, `Wurk::VERSION` still
`1.4.0`, [run 31114866972](https://github.com/developerz-ai/wurk/actions/runs/31114866972)).

Recovering, once the real bump is merged to `main`:

```bash
gh release delete v1.5.0 --yes        # drop the gem-less Release
git push origin --delete v1.5.0       # drop the remote tag
git tag -d v1.5.0                     # and the local one
git tag v1.5.0 <merge-commit> && git push origin v1.5.0
```

Deleting and re-cutting is only safe because **no gem was ever published** for
that version — RubyGems forbids re-pushing a version, so once a `.gem` is live
the number is burned and the next release must take the following one.

1. Checks out, sets up Ruby + Node.
2. Precompiles the Vite SPA into `vendor/assets/` (`rake frontend:build`).
3. **Gate** (`rake release:check`): tag ↔ `Wurk::VERSION`, dashboard bundle +
   manifest present, `CHANGELOG.md` has the matching section, clean tree, tests
   green.
4. **Builds & verifies the gem** (`rake release:package`): packages into `pkg/`
   and asserts the precompiled dashboard is *inside* the `.gem`.
5. **Publishes** via trusted publishing: `rubygems/configure-rubygems-credentials`
   exchanges the OIDC token, then `gem push`.
6. **Cuts a GitHub Release** with the CHANGELOG section as notes and the `.gem`
   attached (marked pre-release automatically for `Gem::Version#prerelease?`).

## What `rake release:check` validates

| Check | Detail |
|---|---|
| **Tag ↔ version** | On a CI tag push, `GITHUB_REF_NAME` (e.g. `v1.1.0`, or `v1.0.0-rc1`) must match `Wurk::VERSION`. Git's hyphenated prerelease maps to RubyGems' dotted form. No-op for local runs. |
| **Dashboard bundle present** | `vendor/assets/dashboard/` has `index.html`, a non-empty `wurk-manifest.json`, and a non-empty `assets/*.js`. Run `rake frontend:build` if missing. |
| **Version ↔ CHANGELOG** | `CHANGELOG.md` contains a `## [<Wurk::VERSION>]` section header. |
| **Clean tree** | `git status --porcelain` is empty, ignoring `vendor/assets/` (built output). |
| **Tests green** | `rake test` (unit + integration + engine) passes. |

(The raising assertions live in `tasks/release_helpers.rb` — testable, and not
packaged into the gem. Covered by `test/unit/release_helpers_test.rb`.)

## Trusted publishing setup (one-time, already configured)

The RubyGems trusted publisher for the `wurk` gem is **already registered** to
this repository's `release` workflow, and the gem exists on
[rubygems.org/gems/wurk](https://rubygems.org/gems/wurk). No API key, no MFA
prompt — publishing is gated entirely on the OIDC identity of the workflow.

If it ever needs to be re-created (new gem, new repo, or rotated publisher), on
rubygems.org → the gem's **Trusted Publishers** → add a GitHub Actions publisher
pointing at:

| Field | Value |
|---|---|
| Repository | `developerz-ai/wurk` |
| Workflow filename | `release.yml` |
| Environment | _(leave blank)_ |

The workflow already requests `permissions: id-token: write`, which is what the
OIDC exchange needs.

## Local one-shot publish (maintainers, fallback only)

`rake release:full` chains `frontend:build → build → push` and pushes with a
local API key (`bin/gem-login` first; MFA enforced via `rubygems_mfa_required`).
Prefer the tag-driven CI flow above; use this only for an out-of-band manual push
when CI is unavailable.
