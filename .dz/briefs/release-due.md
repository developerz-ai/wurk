# Brief: is a release due?

Weekday checkup, fired by `schedules: release-due` in `.dz/maintainer/maintainer.yml`. Wurk releases
like a maintained gem: when merged work that ships has waited for a release, it gets one. Releasing
is `RELEASE.md`; this brief only decides *when*.

## Decide

```bash
# Resolve $last via the GitHub API for the canonical value, then verify the ref (peel to a commit), the release state (zero assets => gem-less => abort), the release baseline (the peeled commit IS the release commit for the tag's version), and the diff window against main. The tag listing is PAGINATED: `git/matching-refs` returns its refs in pages, and `--paginate` is what makes the listing complete — it follows the API's link headers through every page and merges them into one array, so a matching tag that sits on a later page is still enumerated before `sort -V | tail -1` picks the highest version. Without it only the first page is returned and the highest tag SEEN may not be the highest tag that EXISTS.
last=$(gh api --paginate repos/developerz-ai/wurk/git/matching-refs/tags/ \
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
# Verify the release state (RELEASE.md:180-194). The defect trigger is the ASSET COUNT, not the author: a Release with ZERO assets is gem-less (the only state the release-deletion runbook may touch — and only once the RubyGems per-version probe confirms the version was never published, since a succeeded gem push whose Release asset upload failed also leaves zero assets), and a Release that CARRIES the .gem is a real release whatever wrote it — including a `developerz-ai[bot]`-authored one, which is the sanctioned break-glass manual publish (RELEASE.md's "Break-glass manual publish"). The author is read for CONTEXT ONLY and never decides the verdict: treating a bot author as gem-less aborts on a perfectly good release and hides the window behind a false defect. Verify the lookup and its fields before the asset check: with both fields empty (a failed `gh release view`, a missing release), the asset comparison would pass vacuously and an unverified tag would anchor the decision.
rel=$(gh release view "$last" --json author,assets) || { echo "::error::release lookup for $last failed — no GitHub Release was read, so its state is UNCLASSIFIED: either a release.yml preflight no-op (the version is already on RubyGems), a break-glass manual publish (RELEASE.md's 'Break-glass manual publish'), or a failure before the Release was created. RubyGems is the authority — probe https://rubygems.org/api/v2/rubygems/wurk/versions/<version>.json and read the last release.yml run before concluding anything; RELEASE.md's 'Release states' section classifies each state and names the destructive-recovery runbook"; exit 1; }
author=$(echo "$rel" | jq -r '.author.login')
nassets=$(echo "$rel" | jq -r '.assets | length')
[ -n "$author" ] && [ "$author" != "null" ] && [ -n "$nassets" ] && [ "$nassets" != "null" ] || { echo "::error::release $last lookup returned no parsable author/assets"; exit 1; }
[ "$nassets" != "0" ] || { echo "::error::release $last is gem-less (assets=$nassets, author=$author) — zero assets is the gem-less marker but not proof nothing shipped: a succeeded gem push whose Release asset upload failed leaves zero assets too. The release-deletion runbook in RELEASE.md applies to this state ONLY after the RubyGems per-version probe (https://rubygems.org/api/v2/rubygems/wurk/versions/<version>.json) confirms the version was never published"; exit 1; }
# Verify the release baseline before any window work: the peeled commit must be the RELEASE commit for the tag's version. A tag alone proves little — a re-used or hand-cut tag points at a commit that never shipped a version, and every window computed from it is a window since the wrong baseline. The version is the tag without its leading `v`, with git's hyphenated prerelease separator mapped to RubyGems' dot (the same mapping `tag_matches_version!` applies, so the two cannot disagree). The version's dated CHANGELOG heading `## [<version>] - <date>` must be present at the peeled commit, carry that commit's own committer date, and be absent at the commit's first parent — the commit introduced it. Every failure, including a read that cannot run, aborts here, before the Compare call and the local fast path, so no window is ever computed on an unverified baseline.
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

# Detect a shallow checkout (depth-1 from `actions/checkout` with `fetch-depth: 1`, e.g.) and unshallow before any window-bound fetch. `git fetch` deepens only up to the existing shallow boundary, so a tag older than the boundary is fetched without its full ancestry and `git log "$last"..origin/main` walks an incomplete graph — every shipping commit before the boundary is invisible and the window reads empty even when a release is due. `--unshallow` is rejected on a complete repo ("on a complete repository does not make sense"), so the conditional is required and unconditional unshallow is wrong: a complete checkout would error instead of falling through.
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  git fetch --quiet --unshallow origin || { echo "::error::git fetch --unshallow origin failed"; exit 1; }
fi
# Local fast path: the Compare call above is display-only, so this scan is the decision's only window. Both bounds of `$last..origin/main` go stale on a stale checkout: the tag, because the checkout may not have it yet and `git log` against a revision it doesn't know fails; and `origin/main`, because no command above this point updates refs/remotes/origin/main — commits merged since the clone last fetched are invisible, every git command still succeeds, and the window then reads empty, so a release that is due is missed with no error anywhere. Fetch the tag AND main together, before anything reads either revision, with an explicit `+refs/heads/main:refs/remotes/origin/main` refspec so the right bound moves even when the remote's configured fetch refspec differs. The fetch is quiet so its diff noise doesn't drown the window, and its failure aborts: a window computed against a stale ref is worse than none.
git fetch --quiet origin tag "$last" '+refs/heads/main:refs/remotes/origin/main' || { echo "::error::git fetch of tag $last / origin main failed"; exit 1; }
local_last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main)
git log --format='%h %cI %s' "$last"..origin/main -- ':(glob)lib/**/*.rb' ':(glob)lib/**/*.lua' ':(glob)app/**/*.rb' 'config/**' 'exe/*' 'frontend/src/**' wurk.gemspec
```

The baseline check is the difference between "the last release" and "the last tag". A tag on its
own proves little: a re-used or hand-cut tag can point at a commit that never shipped a version,
and a window computed from that tag is a window since the wrong anchor. The peeled commit must
carry the version's dated CHANGELOG heading, the heading's date must be that commit's own
committer date, and the heading must be absent at the commit's first parent — the commit
introduced it. A baseline that cannot be verified aborts the block before any window is computed,
so the decision falls to the unreadable-window row of the table below, never to an empty window.

The release check classifies the Release's state instead of guessing at it. Zero assets is the
gem-less marker and the only state the release-deletion runbook in RELEASE.md may ever touch —
but zero assets alone is not proof that no gem shipped: release.yml pushes the gem BEFORE it
creates the Release and uploads the `.gem` asset, so a push that succeeded and an upload that
failed leave a zero-asset Release on a version RubyGems has already burned, voiding the
runbook's own safety argument. The runbook therefore applies to this state only after the
per-version RubyGems probe has confirmed the version was never published — the precondition
RELEASE.md's "Release states" table puts on the zero-asset row. A Release that carries the `.gem`
is a real release whoever authored it, and a `developerz-ai[bot]`-authored one is the sanctioned
break-glass manual publish, not a defect. The author is read for context only; it never decides
the verdict, because a false "gem-less" abort would hide the window behind a defect that does not
exist. When no Release can be read at all, the state stays unclassified: a release.yml preflight
no-op (the version is already on RubyGems), a break-glass publication, and a failure before the
Release was created are all still open. RubyGems is the authority — probe the per-version endpoint
and read the last release.yml run before concluding anything, and never treat the absence of a
Release as proof that nothing was published.

`$last` is resolved from a PAGINATED listing, and the pagination is the whole reason the listing is
complete. `git/matching-refs/tags` serves its refs in pages; `gh api --paginate` follows the API's
link headers through every page and merges the pages into one array, so every matching tag is
enumerated before `sort -V | tail -1` selects the highest version. A listing that stops at the first
page is not a smaller answer, it is a different one: the highest version SEEN is then only the
highest version on that page, and a newer release whose ref sits on a later page is missed while
the decision still looks complete. Completeness therefore comes from the pagination flag alone — a
fixed page size is not a completeness argument, because no fixed size bounds how many refs the
repository holds; the flag is what guarantees the walk reaches the end of the list. The same flag
shapes the title guard further down, for the same reason.

Those paths are `wurk.gemspec`'s `spec.files`, with three deliberate differences. The dashboard bundle
(`vendor/assets/dashboard/**`) is built at release and git-ignored, so its source, `frontend/src`, is
what a commit changes. `wurk.gemspec` itself is in the window but not in `spec.files`: dependency bumps
live there, never in the gem. `README.md` and `LICENSE` ship but are excluded on purpose: prose alone
never owes a release. Tests, CI, the demo and the benchmarks ship nothing.

The window misses most Dependabot edit sites by construction. Bundler only surfaces through `wurk.gemspec` itself — `Gemfile.lock` is git-ignored and the `Gemfile` is outside the pathspec — so dev-only pins never reach the window. Bun's `frontend/package.json` and `frontend/bun.lock` fall outside the pathspec entirely, so a dashboard bump yields an empty window. The same applies to `.github/workflows/*.yml` and `Dockerfile`: a Dependabot PR there is invisible to the window.

| Window | Do |
|---|---|
| Decide git commands cannot run (worktree-only .git, no object store) or the release baseline check fails | unknown — surface the failure, do not collapse the missing-window case to an empty verdict |
| empty | nothing |
| `Wurk::VERSION` already ahead of `$last` | nothing — a release is in flight (`release.yml`) |
| the oldest shipping commit is under 24 h old | nothing — an org member may still release their own work |
| a **Breaking** change under `## [Unreleased]` | no release ask, ever: a major is a maintainer's. If no open issue says a major is pending, file one, for a maintainer, with no release steps |
| otherwise | one ask, **Release `<next>`**, listing the commits |

`<next>` (only ever reached without a breaking change): `### Added` under `[Unreleased]`, or a `feat`
subject → minor; anything else → patch.

## The ask, when due

1. **Pre-flight guard (gh-capable lane only).** The lane running this brief MUST be a `gh`-capable execution surface — the only surface eligible to file a `Release <next>` ask. Verify capability with `gh auth status`: no `gh` binary, or a non-zero exit, means the lane is not gh-capable, and a lane without `gh` MUST skip this ask entirely. Once eligible, retrieve every open title from BOTH lists — `gh api --paginate "repos/developerz-ai/wurk/issues?state=open" | jq -r '.[] | select(.pull_request == null) | .title'` and `gh api --paginate "repos/developerz-ai/wurk/pulls?state=open" | jq -r '.[].title'`. The list commands `gh issue list` and `gh pr list` reject `--paginate` outright, so a paginated list call would abort on the very flag meant to cover the long tail of open titles; `gh api --paginate` follows the API's link headers through every page so the title guard sees every open issue and PR, not just the newest 30, and is required here, not optional. (The `.pull_request == null` filter on the issues endpoint matches what `gh issue list` returned: GitHub's `/issues` route returns pull requests alongside issues, while `gh issue list` excluded them.) With every page covered, if any title matches `^Release|^release:`, MUST skip the Release ask (standing prohibition, last line of this section — never file a second ask while one titled `Release …` is open).
2. Re-check the window on fresh `main` — the Decide block's local fast path is what fetches it
   (`git fetch --quiet origin tag "$last" '+refs/heads/main:refs/remotes/origin/main'`), so re-run that block rather than
   reading this checkout's `origin/main` as-is; still due, or stop.
3. `## [Unreleased]` empty (a Dependabot-only window)? Add a `### Changed` line per bumped runtime
   dependency first. Read the Dependabot PRs merged in the `$last..main` window only —
   the same window the Decide block walks, and nothing older. Bound the call by date, because
   `--state merged` alone is not a window: with no time or ref bound it returns the repo's
   whole merged history, so the reader would owe `### Changed` lines for gemspec bumps that
   shipped in earlier releases. Bind to the TAGGED COMMIT, never to the release's publication
   timestamp: the ancestry boundary of `$last..main` is the commit `$last` points at, while
   `publishedAt` is when the release was published and can postdate it — a Dependabot PR
   merged in that gap is inside the window, yet a `publishedAt` filter drops it, losing its
   gemspec changelog entry. The bound itself is the tagged commit's committer date —
   `$last` is verified in the Decide block; fetch the commit it points at and take
   `.commit.committer.date` (`gh api "repos/developerz-ai/wurk/commits/$last" --jq
   .commit.committer.date`) as `$last_commit_date`. Settle any candidate whose `merged_at`
   sits near that bound by ancestry, not by timestamp — its `merge_commit_sha` must be one
   of the Compare window's `compare_shas` (every commit in `$last..main`, shipping or not).
   List exhaustively — `gh pr list` cannot: it returns its default 30 results and rejects
   `--paginate` (the reason the title guard uses `gh api --paginate`), so the 31st in-window
   Dependabot PR would silently vanish from the changelog. Walk the pulls endpoint instead:
   `gh api --paginate "repos/developerz-ai/wurk/pulls?state=closed&per_page=100"`, keeping
   each PR whose `.user.login == "dependabot[bot]"` (the account `--app dependabot`
   resolves), `.merged_at != null` and `.merged_at >= $last_commit_date` (pass the date as
   `--arg`; GitHub's RFC3339 stamps compare correctly as strings). Note that ecosystem-bump
   conclusions do NOT come from the Decide window: it is empty for Dependabot edits
   OUTSIDE the seven ship-spec paths by construction — the Decide path filter cannot see
   the `Gemfile`, bun's `frontend/package.json` + `bun.lock`, `.github/workflows/*.yml` or
   the `Dockerfile`, so those bumps leave no trace there. `wurk.gemspec` IS one of the
   seven paths, so a Dependabot PR touching it yields a NON-empty window — that is exactly
   the bump which owes a `### Changed` line below, and its conclusion (ecosystem, target
   file, versions) still comes from this PR list, not from the window's subject line. For
   each in-window merged Dependabot PR, record ecosystem + target file. Owe a `### Changed`
   line only when an in-window merged PR touched `wurk.gemspec`; other ecosystems
   (`Gemfile` dev pins, bun's `frontend/package.json` + `bun.lock`, github-actions, docker)
   owe nothing.

4. `RELEASE.md` → *Cutting a release*: bump `lib/wurk/version.rb`, `bundle exec rake
   release:relock_demo`, move `[Unreleased]` under `## [<next>] - <today>`, `bin/check`.
5. One PR, `release: <next>`, nothing else in it. It merges on green like any PR.
6. Merging it is the release: `release.yml` publishes the gem, then tags. Never tag, never
   `gem push` by hand.

Never file a second ask while one titled `Release …` is open.