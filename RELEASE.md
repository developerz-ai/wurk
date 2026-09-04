# Releasing Wurk

Wurk follows [Semantic Versioning](https://semver.org/). The version of record is
`Wurk::VERSION` in `lib/wurk/version.rb`; the gemspec reads it directly.

The dashboard bundle under `vendor/assets/dashboard/` is **built, not committed**
(it's git-ignored). It must be freshly baked before the gem is packaged so the
precompiled SPA ships inside the gem — consumers never run Node.

Releases publish from CI via **RubyGems Trusted Publishing (OIDC)** — there is no
long-lived `GEM_HOST_API_KEY` secret anywhere. The release workflow exchanges
GitHub's short-lived OIDC token for a scoped RubyGems credential at push time.

## The one rule: the tag is an output, not an input

**Nobody tags a release — CI does, and only after the gem is live.**

`Wurk::VERSION` is the single source of truth. Bumping it on `main` is the
trigger; the tag name is *derived* from it
(`ReleaseHelpers.git_tag_for`), and it is cut last, once RubyGems has accepted
the `.gem`. Three properties fall out of that ordering, and each one closes a
failure this repo actually hit:

- **A tag and a version can never disagree**, because one is computed from the other.
- **Every tag has a gem behind it**, so GitHub's "Latest" can never contradict RubyGems.
- **A failed run leaves no tag**, so re-running is clean and no tag is ever force-moved.

A stray `v*` tag from any source — a bot, a mistake, a fork — is **inert**. It
triggers nothing. See [If a release fails](#if-a-release-fails) for why that
matters more than it sounds.

## Cutting a release

1. **Bump the version** in `lib/wurk/version.rb` (e.g. `1.0.0` → `1.1.0`). For a
   prerelease use RubyGems' dot form: `1.0.0.rc1` (not `1.0.0-rc1`) — CI converts
   it to git's hyphenated `v1.0.0-rc1` for the tag.

2. **Update `CHANGELOG.md`.** Add a dated section whose header matches the new
   version exactly — `## [1.1.0] - YYYY-MM-DD` — with changes grouped under the
   Keep a Changelog headings the file already uses: Added, Changed, Fixed. The
   release workflow lifts this section verbatim into the GitHub Release notes
   (`bin/changelog-section`), so write it for readers.

3. **Build the dashboard bundle and run the gate locally:**
   ```bash
   bundle exec rake frontend:build
   bundle exec rake release:check
   bundle exec rake release:package   # builds the .gem, asserts the SPA is inside it
   ```

4. **Commit** the version + CHANGELOG bump on a branch, open a PR, and merge to
   `main` once green.

**That's it.** Merging step 4 is the release. The `release` workflow fires on
`push: branches: [main], paths: ["lib/wurk/version.rb"]` and does the rest,
end-to-end, with no human-held secret and no tag to push.

Keep the version bump in its own PR, or at least its own commit — anything that
touches `lib/wurk/version.rb` on `main` wakes the release lane.

**Who merges doesn't matter.** The lane is triggered by the push, and every gate
downstream is keyed to the repository and the workflow rather than to the actor:
RubyGems trusted publishing authenticates the *workflow's* OIDC identity, the
GitHub Release uses `github.token`, and the demo deploy is waived past its actor
allowlist by `trusted: true`. So a release merged by the developerz.ai bot
publishes and deploys exactly as one merged by a human.

## What the release workflow does

| # | Job / step | Detail |
|---|---|---|
| 1 | **`preflight`** | Reads `Wurk::VERSION`, derives the tag, and asks RubyGems whether that version already exists. If it does, the run stops here as a no-op — RubyGems forbids re-pushing a version, so its presence is the one idempotency key that cannot drift. This is what makes the workflow safe to re-run and makes a no-op edit to `version.rb` resolve to "nothing to do" instead of a failure. |
| 2 | **checkout + Ruby + bun** | Ruby pinned to 3.4 (the `.gem` is pure Ruby and identical whichever interpreter packs it; the compatibility statement is made by the `test` job). Third-party actions pinned to commit SHAs — this job holds `id-token`. |
| 3 | **build dashboard SPA** | Precompiles the Vite SPA into `vendor/assets/` (`rake frontend:build`). |
| 4 | **release gate** | `rake release:check` — see the table below. |
| 5 | **build & verify gem** | `rake release:package` packages into `pkg/` and asserts the precompiled dashboard is *inside* the `.gem`. |
| 6 | **publish** | `rubygems/configure-rubygems-credentials` exchanges the OIDC token, then `gem push`, then `rubygems-await` blocks on propagation. |
| 7 | **tag & GitHub Release** | `gh release create <tag> --target <sha>` creates the tag *and* the Release in one call, with the CHANGELOG section as notes and the `.gem` attached (marked pre-release automatically for `Gem::Version#prerelease?`). **Last, deliberately** — see [the one rule](#the-one-rule-the-tag-is-an-output-not-an-input). |
| 8 | **`demo`** | Ships the released tag to `wurk.demo.developerz.ai` via the protected `demo` environment. It passes `trusted: true`, which waives deploy-demo's `DEMO_DEPLOYERS` actor allowlist — that allowlist guards the hand-dispatched door, and has nothing to add once this workflow has already published the commit's gem. Waiving it is also what lets a release merged by the developerz.ai bot deploy the demo, rather than stranding it after the irreversible publish. The waiver is honoured only from the `release` workflow running on `main`; anything else passing `trusted: true` is rejected. |

`workflow_dispatch` runs the same lane by hand — use it to retry a release whose
run failed after the bump was already merged.

## What `rake release:check` validates

| Check | Detail |
|---|---|
| **Tag ↔ version** | The workflow passes its derived tag as `WURK_RELEASE_TAG`; it must match `Wurk::VERSION`. Git's hyphenated prerelease (`v1.0.0-rc1`) maps to RubyGems' dotted form (`1.0.0.rc1`). Falls back to `GITHUB_REF_NAME`, and no-ops for local runs. |
| **Dashboard bundle present** | `vendor/assets/dashboard/` has `index.html`, a non-empty `wurk-manifest.json`, and a non-empty `assets/*.js`. Run `rake frontend:build` if missing. |
| **Version ↔ CHANGELOG** | `CHANGELOG.md` contains a `## [<Wurk::VERSION>]` section header. |
| **Unreleased link** | `CHANGELOG.md`'s `[Unreleased]:` compare link starts at `v<Wurk::VERSION>` (the tag about to be cut). |
| **Clean tree** | `git status --porcelain` is empty, ignoring `vendor/assets/` (built output). |
| **Tests green** | `rake test` (unit + integration + engine) passes. |

(The raising assertions live in `tasks/release_helpers.rb` — testable, and not
packaged into the gem. Covered by `test/unit/release_helpers_test.rb`, including
a round-trip test asserting `git_tag_for` and `tag_matches_version!` are exact
inverses — the release lane derives a tag and then re-asserts it through the
gate, so a drift between those two would reject a tag CI had just built.)

## If a release fails

### The failure this lane was built to end

Until 2026-08-11 a **tag push** was the trigger. That made the release lane
writable by anything that could push a tag — and the `developerz-ai[bot]`
maintainer agent could, cutting a `vX.Y.Z` tag and GitHub Release on feature
merges with `Wurk::VERSION` unbumped. Each time:

- `release:check` correctly refused to publish (**no bad gem ever shipped** — the
  gate did its job every single time);
- the release run went **red**, on a tag nobody meant to cut;
- a **GitHub Release marked `Latest` with no gem behind it** was left standing,
  while `gem install wurk` quietly kept serving the previous version.

It happened seven times in three weeks — v1.2.1, v1.5.0, v1.6.0, v1.7.0, v1.8.0,
v1.7.1, v1.7.2 — which is what moved it from "incident" to "design defect". Two
changes retired it:

- **`.maintainer.yml`** sets `release.channels: []`. `manager: none` was *not*
  enough on its own: the `github-release` channel authorized the agent to cut
  releases independently of the manager setting.
- **`release.yml`** no longer listens to tags at all. Even if the agent (or
  anything else) cuts one, nothing fires and nothing goes red.

Defense in depth on purpose: the first is configuration a remote platform has to
honor — this file was once silently discarded for being schema-invalid — and the
second holds regardless of whether it does.

### Recovering a gem-less release

Should one appear anyway, it is cosmetic (no gem shipped) but it lies about the
latest version, so clear it:

```bash
gh release delete vX.Y.Z --cleanup-tag --yes   # drops the Release and the remote tag
git fetch --prune-tags                         # and the local one
```

Then release normally: bump `lib/wurk/version.rb` + `CHANGELOG.md`, merge to
`main`, and let CI cut the tag itself.

Deleting and re-cutting is only safe because **no gem was ever published** for
that version — RubyGems forbids re-pushing a version, so once a `.gem` is live
that number is burned and the next release must take the following one.

### Verifying a release actually shipped

A green run is necessary, not sufficient. The authority is RubyGems, not GitHub:

```bash
curl -s https://rubygems.org/api/v1/versions/wurk.json | head    # the version is there
gem fetch wurk -v X.Y.Z                                          # and the gem ships the SPA
gh release view vX.Y.Z --json author,assets                      # github-actions[bot], .gem attached
```

An `author` of `developerz-ai[bot]` with zero assets means you are looking at a
gem-less release, not a real one.

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
Prefer the CI flow above; use this only for an out-of-band manual push when CI is
unavailable.
