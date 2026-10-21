# Brief: is a release due?

Weekday checkup, fired by `schedules: release-due` in `.dz/maintainer/maintainer.yml`. Wurk releases
like a maintained gem: when merged work that ships has waited for a release, it gets one. Releasing
is `RELEASE.md`; this brief only decides *when*.

## Decide

```bash
# Resolve $last via the GitHub API for the canonical value, then verify the ref (peel to a commit), the release (gem-less marker), and the diff window against main. $last currently resolves to v1.8.0.
last=$(gh api repos/developerz-ai/wurk/git/matching-refs/tags/ \
  | jq -r '.[] | select(.ref | startswith("refs/tags/v")) | .ref | sub("^refs/tags/"; "")' \
  | sort -V \
  | tail -1)

# Peel the tag ref to its commit SHA. Branch on the ref object's type: a lightweight tag's ref object IS the commit (object.type=commit, .object.sha the SHA itself — calling /git/tags/ with it would 404), so its SHA is reused directly; an annotated tag points at a tag object, whose /git/tags/<tag object> entry carries the commit under .object.sha.
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
# Verify the release: gem-less marker = author=developerz-ai[bot] OR assets.length=0 (RELEASE.md:165-172). Verify the lookup and its fields before the marker check: with both fields empty (a failed `gh release view`, a missing release), both marker comparisons would pass vacuously and an unverified tag would anchor the decision.
rel=$(gh release view "$last" --json author,assets) || { echo "::error::release lookup for $last failed"; exit 1; }
author=$(echo "$rel" | jq -r '.author.login')
nassets=$(echo "$rel" | jq -r '.assets | length')
[ -n "$author" ] && [ "$author" != "null" ] && [ -n "$nassets" ] && [ "$nassets" != "null" ] || { echo "::error::release $last lookup returned no parsable author/assets"; exit 1; }
[ "$author" != "developerz-ai[bot]" ] && [ "$nassets" != "0" ] || { echo "::error::release $last is gem-less (author=$author, assets=$nassets)"; exit 1; }
gh api "repos/developerz-ai/wurk/compare/$last...main"

# Local fast path: fetch both the tag AND current main before scanning. The Compare call above is display-only, so this scan is the decision's only window — against a stale origin/main, newly merged shipping commits are invisible and the window collapses to empty. The fetch is quiet so its diff noise doesn't drown the window, and its failure aborts: a window computed against a stale ref is worse than none.
git fetch --quiet origin tag "$last" main:refs/remotes/origin/main || { echo "::error::git fetch of tag $last / origin main failed"; exit 1; }
local_last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main)
git log --format='%h %cI %s' "$last"..origin/main -- 'lib/**/*.rb' 'lib/**/*.lua' 'app/**/*.rb' 'config/**' 'exe/*' 'frontend/src/**' wurk.gemspec
```

Those paths are `wurk.gemspec`'s `spec.files`, with three deliberate differences. The dashboard bundle
(`vendor/assets/dashboard/**`) is built at release and git-ignored, so its source, `frontend/src`, is
what a commit changes. `wurk.gemspec` itself is in the window but not in `spec.files`: dependency bumps
live there, never in the gem. `README.md` and `LICENSE` ship but are excluded on purpose: prose alone
never owes a release. Tests, CI, the demo and the benchmarks ship nothing.

| Window | Do |
|---|---|
| Decide git commands cannot run (worktree-only .git, no object store) | unknown — surface the failure, do not collapse the missing-window case to an empty verdict |
| empty | nothing |
| `Wurk::VERSION` already ahead of `$last` | nothing — a release is in flight (`release.yml`) |
| the oldest shipping commit is under 24 h old | nothing — an org member may still release their own work |
| a **Breaking** change under `## [Unreleased]` | no release ask, ever: a major is a maintainer's. If no open issue says a major is pending, file one, for a maintainer, with no release steps |
| otherwise | one ask, **Release `<next>`**, listing the commits |

`<next>` (only ever reached without a breaking change): `### Added` under `[Unreleased]`, or a `feat`
subject → minor; anything else → patch.

## The ask, when due

1. **Pre-flight guard (gh-capable lane only).** The lane running this brief MUST be a `gh`-capable execution surface — the only surface eligible to file a `Release <next>` ask. Verify capability with `gh auth status`: no `gh` binary, or a non-zero exit, means the lane is not gh-capable, and a lane without `gh` MUST skip this ask entirely. Once eligible, retrieve every open title from BOTH lists — `gh api --paginate "repos/developerz-ai/wurk/issues?state=open" | jq -r '.[] | select(.pull_request == null) | .title'` and `gh api --paginate "repos/developerz-ai/wurk/pulls?state=open" | jq -r '.[].title'`. The list commands `gh issue list` and `gh pr list` reject `--paginate` outright, so a paginated list call would abort on the very flag meant to cover the long tail of open titles; `gh api --paginate` follows the API's link headers through every page so the title guard sees every open issue and PR, not just the newest 30, and is required here, not optional. (The `.pull_request == null` filter on the issues endpoint matches what `gh issue list` returned: GitHub's `/issues` route returns pull requests alongside issues, while `gh issue list` excluded them.) With every page covered, if any title matches `^Release|^release:`, MUST skip the Release ask (standing prohibition, line 127 below — never file a second ask while one titled `Release …` is open).
2. Re-check the window on fresh `main`; still due, or stop.
3. `## [Unreleased]` empty (a Dependabot-only window)? Add a `### Changed` line per bumped runtime
   dependency first.
4. `RELEASE.md` → *Cutting a release*: bump `lib/wurk/version.rb`, `bundle exec rake
   release:relock_demo`, move `[Unreleased]` under `## [<next>] - <today>`, `bin/check`.
5. One PR, `release: <next>`, nothing else in it. It merges on green like any PR.
6. Merging it is the release: `release.yml` publishes the gem, then tags. Never tag, never
   `gem push` by hand.

Never file a second ask while one titled `Release …` is open.