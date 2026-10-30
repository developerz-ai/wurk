# Brief: is a release due?

Weekday checkup (`schedules: release-due`). Releasing is `RELEASE.md`; this brief only decides *when*.

## Decide

```bash
# Resolve $last (paginated), peel it to a commit, classify its Release (RELEASE.md:180-194), verify the baseline, then scan the window.
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
rel=$(gh release view "$last" --json author,assets) || { echo "::error::release lookup for $last failed: state unclassified (a release.yml preflight no-op, a break-glass publish, or a failure before the Release was created). Probe https://rubygems.org/api/v2/rubygems/wurk/versions/<version>.json and the last release.yml run; RELEASE.md's 'Release states' classifies each"; exit 1; }
author=$(echo "$rel" | jq -r '.author.login')
nassets=$(echo "$rel" | jq -r '.assets | length')
[ -n "$author" ] && [ "$author" != "null" ] && [ -n "$nassets" ] && [ "$nassets" != "null" ] || { echo "::error::release $last lookup returned no parsable author/assets"; exit 1; }
[ "$nassets" != "0" ] || { echo "::error::release $last is gem-less (assets=$nassets, author=$author). Zero assets is not proof: RELEASE.md's deletion runbook applies only once https://rubygems.org/api/v2/rubygems/wurk/versions/<version>.json shows it was never published"; exit 1; }
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
git log --format='%h %cI %s' "$last"..origin/main -- ':(glob)lib/**/*.rb' ':(glob)lib/**/*.lua' ':(glob)app/**/*.rb' 'config/**' 'exe/*' 'frontend/src/**' 'frontend/index.html' 'frontend/public/**' wurk.gemspec
```

- **Tag listing.** Its completeness comes from pagination (`--paginate`), never a page size.
- **Baseline.** A tag alone proves little. The peeled commit must carry the version's dated `## [<version>] - <date>` heading, dated with that commit's own committer date, and absent at its first parent: the release commit introduced it.
- **Release state.** Zero assets is the gem-less marker, but not proof nothing shipped: `release.yml` pushes the gem before it uploads the asset. The release-deletion runbook in RELEASE.md applies only once the RubyGems per-version probe confirms the version was never published. A Release carrying the `.gem` is real, whoever authored it.
- **Window.** The pathspec names the sources whose change reaches the gem: `lib/**`, `app/**`, `config/**`, `exe/*` and `wurk.gemspec`, plus the dashboard sources behind the shipped `vendor/assets/dashboard/**/*` — `frontend/src/**`, `frontend/index.html` (Vite builds it into the bundle's `index.html`) and `frontend/public/**` (copied verbatim). The gem ships the built dashboard, not the sources, so the scan names the sources. Prose, tests, CI, the demo and benchmarks ship nothing.

| Window | Do |
|---|---|
| Decide git commands cannot run (worktree-only .git, no object store) or the release baseline check fails | unknown — surface the failure, do not collapse the missing-window case to an empty verdict |
| empty | nothing |
| `Wurk::VERSION` already ahead of `$last` | nothing — a release is in flight (`release.yml`) |
| the oldest shipping commit is under 24 h old | nothing — an org member may still release their own work |
| a **Breaking** change under `## [Unreleased]` | no release ask, ever: a major is a maintainer's. If no open issue says a major is pending, file one, for a maintainer, with no release steps |
| otherwise | one ask, **Release `<next>`**, listing the commits |

`<next>` (only ever reached without a breaking change): `### Added` under `[Unreleased]`, or a `feat` subject → minor; anything else → patch.

## Rows

- `tag-listing` — resolves `$last`, the highest tag, through the paginated matching-refs listing whose completeness comes from pagination.
- `tag-peel` — peels the tag ref to its release commit and aborts when the ref does not resolve to a commit.
- `release-state` — classifies the Release at `$last` from `author` and `assets`; zero assets aborts as gem-less, with the deletion runbook gated behind the RubyGems per-version probe.
- `baseline` — the peeled commit carries the version's dated CHANGELOG heading, dated with that commit's own committer date and absent at its first parent.
- `window` — scans `$last..main` for shipping commits through the shipping pathspec and grades the Window/Do table's verdict.
- `pre-flight-guard` — only a lane where `gh auth status` exits 0 files the ask, only when no open issue or PR title matches `^Release|^release:`, and never a second ask while one titled `Release …` is open.

## The ask, when due

1. **Pre-flight guard.** Only a lane where `gh auth status` exits 0 files the ask. Authentication is `gh`'s standard credential interface, `GH_TOKEN`: a non-Actions executor MUST have `GH_TOKEN` securely injected at its point of use. This brief names it only, never a token value, a storage location or a provisioning mechanism. Skip if any open title from `gh api --paginate "repos/developerz-ai/wurk/issues?state=open" | jq -r '.[] | select(.pull_request == null) | .title'` or `gh api --paginate "repos/developerz-ai/wurk/pulls?state=open" | jq -r '.[].title'` matches `^Release|^release:`.
2. Re-run the Decide block on fresh `main`; still due, or stop.
3. `[Unreleased]` empty (a Dependabot-only window)? Add one `### Changed` line per in-window merged Dependabot PR that touched `wurk.gemspec`; other ecosystems owe nothing. In-window: `merged_at` at or after the committer date of the commit `$last` peels to (not the Release's `publishedAt`), from `gh api --paginate "repos/developerz-ai/wurk/pulls?state=closed&per_page=100"`.
4. `RELEASE.md` → *Cutting a release*: bump `lib/wurk/version.rb`, `bundle exec rake release:relock_demo`, move `[Unreleased]` under `## [<next>] - <today>`, `bin/check`.
5. One PR, `release: <next>`, nothing else; it merges on green, and that is the release: `release.yml` publishes the gem, then tags the merge commit. Never tag, never `gem push` by hand: a tag pushed without a version bump is what made every gem-less release in wurk#420.
6. Watch that `release.yml` run. A `startup_failure` publishes nothing: a called workflow wants a permission its caller lacks (`demo` must grant `deployments: write`, wurk#859). Fix the lane, revert the bump, re-land `release: <next>`: a `workflow_dispatch` retry tags a later commit, which fails the baseline check.

The ask's body carries the Decide block's own evidence:

- the resolved `$last` tag and its peeled, baseline-verified release commit;
- the window's commit list as the local fast path prints it, with the oldest shipping commit's timestamp (the figure the 24 h row grades);
- the `[Unreleased]` CHANGELOG contents the derivation read;
- `<next>` and its rule (`### Added` or a `feat` subject → minor, else patch);
- any in-window merged Dependabot PR that touched `wurk.gemspec`, with the `### Changed` line it owes.

Health-checkup evidence is not ask evidence: CI verdicts on main, a RubyGems probe of the current version, and demo state never substitute for the baseline, the window or the derivation.

Never file a second ask while one titled `Release …` is open.
