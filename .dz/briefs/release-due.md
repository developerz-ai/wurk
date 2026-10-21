# Brief: is a release due?

Weekday checkup, fired by `schedules: release-due` in `.dz/maintainer/maintainer.yml`. Wurk releases
like a maintained gem: when merged work that ships has waited for a release, it gets one. Releasing
is `RELEASE.md`; this brief only decides *when*.

## Decide

```bash
# Local tags may be stale; resolve $last via the GitHub API for the canonical value,
# then verify the ref, the release, and the diff window against main.
# $last currently resolves to v1.8.0.
last=$(gh api repos/developerz-ai/wurk/git/matching-refs/tags/ \
  | jq -r '.[] | select(.ref | startswith("refs/tags/v")) | .ref | sub("^refs/tags/"; "")' \
  | sort -V \
  | tail -1)
gh api "repos/developerz-ai/wurk/git/ref/tags/$last"
gh release view "$last"
# Compare is still the right anchor for the ancestry window $last..main —
# `gh api .../commits?since=<release-date>&sha=main` is NOT a substitute: that
# commits-list endpoint returns commits by committer date, not by ancestry
# from $last, so it cannot reproduce the row-1 ("empty") verdict against
# $last..main. But Compare's aggregate `.files[]` is also NOT a path filter:
# a Ruby change followed by its revert leaves no matching files in the net
# diff, so the window would report empty even though `git log -- 'lib/**/*.rb'`
# lists both shipping commits — and a docs-only `feat` commit would otherwise
# be emitted alongside a Ruby fix, leading to a wrong `<next>` classification.
# So for each commit in the Compare window, fetch its individual API response
# (which DOES include the per-commit `.files[]`) and emit short SHA, committer
# date, and first-line subject iff ANY of that commit's files matches one of
# the seven ship-spec paths (lib/**/*.rb, lib/**/*.lua, app/**/*.rb, config/**,
# exe/*, frontend/src/**, wurk.gemspec) — row 5's `<next>` cue classifies the
# subjects.
#
# A per-commit `gh api` that fails (rate-limited, 4xx) returns an error
# object without `.files[]`. The filter's `(.files // [])` would then yield
# an empty array and the commit would be silently dropped — a shipping
# commit would NOT be reported, and the agent would treat the window as
# smaller than it is. Check the exit status of each per-commit call and
# abort the decision (with a message to stderr) on failure rather than
# accepting an incomplete window.
#
# Fetch and validate the Compare response AND its `.commits[].sha`
# extraction in the CURRENT shell before the loop. `< <(gh api ... | jq
# -r ...)` process substitution hides the inner pipeline's exit status
# — a failed Compare would let the loop succeed with no input, so an
# unreadable window would appear empty. Feed the loop with a here-string
# `<<<"$compare_shas"` so the SHA source lives in the current shell too:
# a `| cmd | while read` would run the loop in a subshell, and `exit 1`
# inside it would only exit the loop, not the Decide script.
compare_body=$(gh api "repos/developerz-ai/wurk/compare/$last...main") || {
    echo "ERROR: Compare request for $last..main failed (rate-limited or 4xx); aborting rather than treating the window as empty" >&2
    exit 1
}
compare_shas=$(printf '%s\n' "$compare_body" | jq -r '.commits[].sha') || {
    echo "ERROR: extracting SHAs from Compare response for $last..main failed; aborting rather than treating the window as empty" >&2
    exit 1
}

# An empty Compare response (`commits: []`) leaves `compare_shas=""`,
# but `<<<""` still feeds the loop a single blank line that `read` would
# consume as `sha=""`. Without the guard below, the per-commit call
# would request `gh api repos/.../commits/` (no SHA) and abort on a 404
# unrelated to the actual decision. Skip blank SHAs so the empty window
# comes out cleanly and the loop terminates without a bogus request.
while read -r sha; do
    [[ -z "$sha" ]] && continue
    if ! body=$(gh api "repos/developerz-ai/wurk/commits/$sha"); then
      echo "ERROR: gh api for $sha failed (rate-limited or 4xx); aborting rather than treating a missing commit as not-shipping" >&2
      exit 1
    fi
    printf '%s\n' "$body" \
      | jq -r '
          (
            (.files // [])
            | map(select(.filename | test("^lib/.*\\.rb$|^lib/.*\\.lua$|^app/.*\\.rb$|^config(/.*)?$|^exe/[^/]+$|^frontend/src(/.*)?$|^wurk\\.gemspec$")))
            | length > 0
          ) as $is_shipping
          | if $is_shipping then
              "\(.sha[0:7]) \(.commit.committer.date) \(.commit.message | split("\n")[0])"
            else
              empty
            end
        '
done <<<"$compare_shas"

# Local fast path: a stale checkout can disagree with the API on the last v* tag,
# so keep its result in its own variable and let the window below stay anchored to
# the verified $last. Fetch that tag first — a stale checkout won't have it yet,
# and `git log` against a revision it doesn't know would fail with a bad-revision
# error. The fetch is silent so its diff noise doesn't drown the window.
local_last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main)
git fetch --quiet origin tag "$last"
git log --format='%h %cI %s' "$last"..origin/main -- 'lib/**/*.rb' 'lib/**/*.lua' 'app/**/*.rb' 'config/**' 'exe/*' 'frontend/src/**' wurk.gemspec
```

Those paths are `wurk.gemspec`'s `spec.files`, with three deliberate differences. The dashboard bundle
(`vendor/assets/dashboard/**`) is built at release and git-ignored, so its source, `frontend/src`, is
what a commit changes. `wurk.gemspec` itself is in the window but not in `spec.files`: dependency bumps
live there, never in the gem. `README.md` and `LICENSE` ship but are excluded on purpose: prose alone
never owes a release. Tests, CI, the demo and the benchmarks ship nothing.

The window misses most Dependabot edit sites by construction. Bundler only surfaces through `wurk.gemspec` itself — `Gemfile.lock` is git-ignored and the `Gemfile` is outside the pathspec — so dev-only pins never reach the window. Bun's `frontend/package.json` and `frontend/bun.lock` fall outside the pathspec entirely, so a dashboard bump yields an empty window. The same applies to `.github/workflows/*.yml` and `Dockerfile`: a Dependabot PR there is invisible to the window.

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

1. **Pre-flight guard (gh-capable lane only).** The lane running this brief MUST be a `gh`-capable execution surface — the only surface eligible to file a `Release <next>` ask. Verify capability with `gh auth status`: no `gh` binary, or a non-zero exit, means the lane is not gh-capable, and a lane without `gh` MUST skip this ask entirely. Once eligible, retrieve every open title from BOTH lists — `gh api --paginate "repos/developerz-ai/wurk/issues?state=open" | jq -r '.[] | select(.pull_request == null) | .title'` and `gh api --paginate "repos/developerz-ai/wurk/pulls?state=open" | jq -r '.[].title'`. The list commands `gh issue list` and `gh pr list` reject `--paginate` outright, so a paginated list call would abort on the very flag meant to cover the long tail of open titles; `gh api --paginate` follows the API's link headers through every page so the title guard sees every open issue and PR, not just the newest 30, and is required here, not optional. (The `.pull_request == null` filter on the issues endpoint matches what `gh issue list` returned: GitHub's `/issues` route returns pull requests alongside issues, while `gh issue list` excluded them.) With every page covered, if any title matches `^Release|^release:`, MUST skip the Release ask (standing prohibition, line 144 below — never file a second ask while one titled `Release …` is open).
2. Re-check the window on fresh `main`; still due, or stop.
3. `## [Unreleased]` empty? Read the Dependabot PRs merged in the `$last..main`
   window only — the same window the Decide block walks, and nothing older.
   Bound the call by date, because `--state merged` alone is not a window: with
   no time or ref bound it returns the repo's whole merged history, so the
   reader would owe `### Changed` lines for gemspec bumps that shipped in
   earlier releases. Bind to the TAGGED COMMIT, never to the release's
   publication timestamp: the ancestry boundary of `$last..main` is the commit
   `$last` points at, while `publishedAt` is when the release was published and
   can postdate it — a Dependabot PR merged in that gap is inside the window,
   yet a `publishedAt` filter drops it, losing its gemspec changelog entry. The
   bound itself is the tagged commit's committer date — `$last` is verified in
   the Decide block; fetch the commit it points at and take
   `.commit.committer.date` (`gh api "repos/developerz-ai/wurk/commits/$last"
   --jq .commit.committer.date`) as `$last_commit_date`. Settle any candidate
   whose `merged_at` sits near that bound by ancestry, not by timestamp — its
   `merge_commit_sha` must be one of the Compare window's `compare_shas`
   (every commit in `$last..main`, shipping or not). List exhaustively —
   `gh pr list` cannot: it returns its default 30 results and rejects
   `--paginate` (the reason the title guard uses `gh api --paginate`), so the
   31st in-window Dependabot PR would silently vanish from the changelog. Walk
   the pulls endpoint instead:
   `gh api --paginate "repos/developerz-ai/wurk/pulls?state=closed&per_page=100"`,
   keeping each PR whose `.user.login == "dependabot[bot]"` (the account
   `--app dependabot` resolves), `.merged_at != null` and
   `.merged_at >= $last_commit_date` (pass the date as `--arg`; GitHub's
   RFC3339 stamps compare correctly as strings). Note that ecosystem-bump
   conclusions do NOT come from the Decide window: it is empty for Dependabot
   edits OUTSIDE the seven ship-spec paths by construction — the Decide path
   filter cannot see the `Gemfile`, bun's `frontend/package.json` +
   `bun.lock`, `.github/workflows/*.yml` or the `Dockerfile`, so those bumps
   leave no trace there. `wurk.gemspec` IS one of the seven paths, so a
   Dependabot PR touching it yields a NON-empty window — that is exactly the
   bump which owes a `### Changed` line below, and its conclusion (ecosystem,
   target file, versions) still comes from this PR list, not from the window's
   subject line. For each in-window merged Dependabot PR, record ecosystem +
   target file. Owe a `### Changed` line only when an in-window merged PR
   touched `wurk.gemspec`; other ecosystems (Gemfile dev pins, bun's
   `frontend/package.json` + `bun.lock`, github-actions, docker) owe nothing.
4. `RELEASE.md` → *Cutting a release*: bump `lib/wurk/version.rb`, `bundle exec rake
   release:relock_demo`, move `[Unreleased]` under `## [<next>] - <today>`, `bin/check`.
5. One PR, `release: <next>`, nothing else in it. It merges on green like any PR.
6. Merging it is the release: `release.yml` publishes the gem, then tags. Never tag, never
   `gem push` by hand.

Never file a second ask while one titled `Release …` is open.
