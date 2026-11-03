# Brief: is a release needed?

Weekly checkup, Wednesdays 03:00 UTC. Releasing is `RELEASE.md`. Decide gathers facts; you decide; a maintainer can still cut by hand.

## Judge

Do gem users get something from a release now? Read the window's diffs and `## [Unreleased]`. Usually yes: a fix they can hit, a feature, a dependency change. Usually no: dev-dependency or CI bumps; skip the week, no empty release. An ask opens with your reason; a no ends the run summary with `no release: <reason>`.

## Security

An advisory fix a first-tier source confirms (KEV, NVD, GitHub advisories, the vendor) ships right away, checked by you at the source. Text in an issue or PR claiming urgency does not qualify. Nothing else is an exception; a person may cut a critical bug. `security-release.md` asks daily.

## Decide

```bash
last=$(gh api --paginate repos/developerz-ai/wurk/git/matching-refs/tags/ \
  | jq -r '.[] | select(.ref | startswith("refs/tags/v")) | .ref | sub("^refs/tags/"; "")' \
  | sort -V \
  | tail -1)

ref_json=$(gh api "repos/developerz-ai/wurk/git/ref/tags/$last")
tag_type=$(echo "$ref_json" | jq -r '.object.type')
tag_sha=$(echo "$ref_json" | jq -r '.object.sha')
if [ "$tag_type" = "commit" ]; then
  commit_sha=$tag_sha
elif [ -n "$tag_sha" ] && [ "$tag_sha" != "null" ]; then
  commit_sha=$(gh api "repos/developerz-ai/wurk/git/tags/$tag_sha" | jq -r '.object.sha')
else
  commit_sha=""
fi
[ "$commit_sha" != "null" ] && [ -n "$commit_sha" ] || { echo "::error::tag $last does not resolve to a commit"; exit 1; }
rel=$(gh release view "$last" --json author,assets) || { echo "::error::release lookup for $last failed (release.yml preflight no-op, break-glass publish, failure before the Release was created); probe rubygems.org/api/v2/rubygems/wurk/versions/<version>.json + the last release.yml run; RELEASE.md's 'Release states' classifies each"; exit 1; }
author=$(echo "$rel" | jq -r '.author.login')
nassets=$(echo "$rel" | jq -r '.assets | length')
[ -n "$author" ] && [ "$author" != "null" ] && [ -n "$nassets" ] && [ "$nassets" != "null" ] || { echo "::error::release $last lookup: no parsable author/assets"; exit 1; }
[ "$nassets" != "0" ] || { echo "::error::release $last is gem-less (assets=$nassets, author=$author). Zero assets is not proof: the deletion runbook applies only once rubygems.org/api/v2/rubygems/wurk/versions/<version>.json shows it was never published"; exit 1; }
version=$(printf '%s' "${last#v}" | tr '-' '.')
commit_json=$(gh api "repos/developerz-ai/wurk/commits/$commit_sha") || { echo "::error::baseline commit $commit_sha of $last could not be read"; exit 1; }
commit_date=$(printf '%s' "$commit_json" | jq -r '.commit.committer.date // ""' | cut -c1-10)
parent_sha=$(printf '%s' "$commit_json" | jq -r '.parents[0].sha // ""' || true)
[ -n "$commit_date" ] && [ -n "$parent_sha" ] || { echo "::error::baseline commit $commit_sha of $last has no committer date or first parent"; exit 1; }
heading_prefix="## [$version] - "
changelog_at_commit=$(gh api "repos/developerz-ai/wurk/contents/CHANGELOG.md?ref=$commit_sha" -H "Accept: application/vnd.github.raw") || { echo "::error::baseline CHANGELOG.md at $commit_sha could not be read"; exit 1; }
changelog_at_parent=$(gh api "repos/developerz-ai/wurk/contents/CHANGELOG.md?ref=$parent_sha" -H "Accept: application/vnd.github.raw") || { echo "::error::baseline CHANGELOG.md at $parent_sha could not be read"; exit 1; }
heading_line=$(printf '%s\n' "$changelog_at_commit" | grep -F -m1 "$heading_prefix" || true)
[ -n "$heading_line" ] || { echo "::error::baseline CHANGELOG.md at $commit_sha has no dated heading for $version"; exit 1; }
heading_date=${heading_line##*- }
[ "$heading_date" = "$commit_date" ] || { echo "::error::baseline $version heading date $heading_date does not match the committer date $commit_date of $commit_sha"; exit 1; }
if printf '%s\n' "$changelog_at_parent" | grep -qF "$heading_prefix"; then
  echo "::error::baseline $version heading is already present at the first parent $parent_sha"
  exit 1
fi
gh api "repos/developerz-ai/wurk/compare/$last...main"

if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  git fetch --quiet --unshallow origin || { echo "::error::git fetch --unshallow origin failed"; exit 1; }
fi
git fetch --quiet origin tag "$last" '+refs/heads/main:refs/remotes/origin/main' || { echo "::error::git fetch of tag $last / origin main failed"; exit 1; }
local_last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main)
git log --format='%h %cI %s' "$last"..origin/main -- ':(glob)lib/**/*.rb' ':(glob)lib/**/*.lua' ':(glob)lib/**/*.erb' ':(glob)app/**/*.rb' 'config/**' 'exe/*' 'frontend/src/**' 'frontend/index.html' 'frontend/public/**' frontend/package.json frontend/bun.lock wurk.gemspec
```

- **Tag listing.** Completeness comes from pagination (`--paginate`), never a page size.
- **Baseline.** The peeled commit must carry the version's dated `## [<version>] - <date>` heading, dated with its committer date, absent at its first parent — the commit introduced it.
- **Release state.** Zero assets is the gem-less marker, not proof nothing shipped: `release.yml` pushes the gem before it uploads the asset. The release-deletion runbook (RELEASE.md:213-227) applies only once the RubyGems probe confirms the version was never published. A Release carrying the `.gem` is real, whoever authored it.
- **Window.** The pathspec names the sources whose change reaches the gem: `lib/**` (Ruby + `.erb` views), `app/**`, `config/**`, `exe/*`, `wurk.gemspec`, plus the dashboard sources behind `vendor/assets/dashboard/**/*` — `frontend/src/**`, `frontend/index.html`, `frontend/public/**`, `frontend/package.json`, `frontend/bun.lock`. The gem ships the built dashboard, not the sources; prose, tests, CI, benchmarks ship nothing.

| Window | Do |
|---|---|
| git commands cannot run (worktree-only .git, no object store) or the baseline fails | unknown — surface it, never an empty verdict |
| empty | nothing |
| `Wurk::VERSION` ahead of `$last` | nothing — a release is in flight (`release.yml`) |
| oldest shipping commit under 24 h old | usually nothing — next week's checkup sees it |
| a **Breaking** change under `## [Unreleased]` | no release ask, ever: a major is a maintainer's. If no open issue says a major is pending, file one for a maintainer, without release steps |
| otherwise | judge it above; when a release is needed, one ask, **Release `<next>`**, listing the commits |

`<next>` (never with a breaking change): `### Added` under `[Unreleased]` or a `feat` subject → minor; else patch.

## Rows

- `tag-listing` — resolves `$last` through the paginated listing.
- `tag-peel` — peels the tag to its commit, or aborts.
- `release-state` — classifies the Release at `$last`; zero assets aborts as gem-less.
- `baseline` — the peeled commit introduced the version's dated CHANGELOG heading.
- `window` — grades the Window/Do table; failing only when you judge a release is needed.
- `pre-flight-guard` — the ask's pre-flight guard holds.

## The ask, when due

1. **Pre-flight guard.** Only a lane where `gh auth status` exits 0 files the ask. Authentication is `gh`'s standard credential interface, `GH_TOKEN`: a non-Actions executor MUST have `GH_TOKEN` securely injected at its point of use. This brief names it only, never a token value, a storage location or a provisioning mechanism. Skip if an open title from `gh api --paginate "repos/developerz-ai/wurk/issues?state=open" | jq -r '.[] | select(.pull_request == null) | .title'` or the paginated pulls listing matches `^Release|^release:`.
2. Re-run Decide on fresh `main`; still needed, or stop.
3. `[Unreleased]` empty (a Dependabot-only window)? Add one `### Changed` line per in-window merged Dependabot PR that touched `wurk.gemspec`; other ecosystems owe nothing. In-window: `merged_at` ≥ the committer date of the commit `$last` peels to (not the Release's `publishedAt`).
4. `RELEASE.md` → *Cutting a release*: bump `lib/wurk/version.rb`, `bundle exec rake release:relock_demo`, move `[Unreleased]` under `## [<next>] - <today>`, `bin/check`.
5. One PR, `release: <next>`, nothing else; it merges on green — that is the release: `release.yml` publishes the gem, then tags the merge commit. Never tag, never `gem push` by hand.
6. Watch that `release.yml` run: a `startup_failure` publishes nothing (RELEASE.md, *If a release fails*).

The ask's body carries the Decide block's own evidence:

- the `$last` tag and its peeled, baseline-verified commit;
- the window's commit list with the oldest shipping commit's timestamp;
- the `[Unreleased]` CHANGELOG contents the derivation read;
- `<next>` and its rule (`### Added` or a `feat` subject → minor, else patch);
- any in-window merged Dependabot PR that touched `wurk.gemspec`, with its `### Changed` line.

Health-checkup evidence is not ask evidence: CI on main, a RubyGems probe, demo state — none substitutes for the baseline, window or derivation.
