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
gh api "repos/developerz-ai/wurk/compare/$last...main"

# Local fast path: a stale checkout can disagree with the API on the last v* tag,
# so keep its result in its own variable and let the window below stay anchored to
# the verified $last. Fetch that tag first — a stale checkout won't have it yet,
# and `git log` against a revision it doesn't know would fail with an unknown
# revision. The fetch is silent so its diff noise doesn't drown the window.
local_last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main)
git fetch --quiet origin tag "$last"
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

1. Re-check the window on fresh `main`; still due, or stop.
2. `## [Unreleased]` empty (a Dependabot-only window)? Add a `### Changed` line per bumped runtime
   dependency first.
3. `RELEASE.md` → *Cutting a release*: bump `lib/wurk/version.rb`, `bundle exec rake
   release:relock_demo`, move `[Unreleased]` under `## [<next>] - <today>`, `bin/check`.
4. One PR, `release: <next>`, nothing else in it. It merges on green like any PR.
5. Merging it is the release: `release.yml` publishes the gem, then tags. Never tag, never
   `gem push` by hand.

Never file a second ask while one titled `Release …` is open.

## Findings

### Run context

This seat was given the Decide section's two `git` invocations to run and, on `git` failure, the
fallback `gh api repos/developerz-ai/wurk/git/refs/tags`. The runner refuses both `git` and `gh`
on this checkout by design ("the runner owns commits and releases"), so neither the primary nor
the substitute path could be executed. The Findings below record the verbatim refusal for each
attempted command and the in-tree file reads I did instead, so the audit row shows what was
asked, what was refused, and what was read directly.

### Command 1 — `git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main` (release-due.md:10)

Attempted:

```
last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' origin/main)
```

Result (verbatim from the runner):

```
[code shell] refusing to run `git`: the runner owns commits and releases (deterministic, audited SHAs). Make the change here and let the runner commit it. To see what you have changed, call code_changes: it lists the changed files and shows the diff for the paths you name.
```

`$last` was therefore not assigned by the runner; it is taken from the loose-ref below
instead.

### Command 2 — `git log --format='%h %cI %s' "$last"..origin/main -- …` (release-due.md:11)

Not run. The brief pairs this with Command 1 via the shared `$last` variable, so issuing it
without Command 1 succeeding would be a different (and a wrong) command. Recorded here as
"not attempted" rather than "failed": the runner refused the prerequisite, not this command.

### Fallback — `gh api repos/developerz-ai/wurk/git/refs/tags`

The brief's fallback clause: *If `git` fails (worktree pointer, unreachable origin), fall back to
`gh api repos/developerz-ai/wurk/git/refs/tags` and record the limitation.*

Attempted:

```
gh api repos/developerz-ai/wurk/git/refs/tags
```

Result (verbatim from the runner):

```
[code shell] refusing to run `gh`: the runner owns commits and releases (deterministic, audited SHAs). Make the change here and let the runner commit it.
```

The substitute is also unavailable from this seat. Per the brief, this refusal is itself the
limitation the Findings block must record.

### In-tree signals read directly (no runner mediation)

Direct file reads; not command output. Recorded so the next seat holding one of the unavailable
tools can act on them without re-spending a budget.

- `lib/wurk/version.rb:4` — `Wurk::VERSION = '1.8.0'`.
- `CHANGELOG.md:7` — `## [1.8.0] - 2026-10-05` (the dated heading the brief points at as the
  v1.8.0 release commit's mark).
- `CHANGELOG.md:5-6` — `## [Unreleased]` is the heading on line 5 with line 6 blank and the
  next heading on line 7 being `## [1.8.0] - 2026-10-05`; there is no `###` subsection under
  `[Unreleased]`. Per release-due.md:24 this rules out the Breaking-change row of the decision
  table.
- `demo/Gemfile.lock:4` — pins `wurk (1.8.0)` (per the coordinator's team context; locked against
  the same source as the library version).
- `.git/refs/tags/v1.8.0` → `2917967b5abb3ece75a5726d5cbd41c6c2518902` (file content; loose tag,
  not in `packed-refs`). This is the SHA stored in the loose-ref file; for an annotated tag
  it is the tag object, not the commit the tag peels to, and for a lightweight tag it is the
  commit directly. Without `git cat-file -p v1.8.0` (refused here, release-due.md:45-95) the
  form cannot be determined and the commit the tag is actually placed at is not knowable
  from this seat. Recording it as "the v1.8.0 release commit" is therefore unsafe.
- `.git/packed-refs` — most recent `v*` tag it lists is `88c0631abb4460c8d8a694d1dc8fa4a42664d323`
  for `refs/tags/v1.7.6`. The v1.8.0 entry is held in the loose-refs file above, not in
  `packed-refs`, so `git for-each-ref` would find it, but `git` cannot be invoked here.
- `.git/HEAD` → `ref: refs/heads/dz/execute-decide-commands-confirm-v1-8-0-in-shell--f4aa534a`,
  i.e. the working branch this editor sits on, not `refs/heads/main` and not a remote tracking
  ref.
- `.git/refs/remotes/origin/main` → `261b9fd92c77334704873ea2db726bd5089d61b2` (read directly
  as a file, no `git` needed). This SHA differs from the tag's stored SHA above; whether
  `origin/main` is past, equal to, or behind the v1.8.0 release commit is not decidable
  without peeling the tag (see "v1.8.0 disposition" below).

### v1.8.0 disposition vs `Wurk::VERSION` and the 1.8.0 release commit (CHANGELOG.md:7)

**Placement of `refs/tags/v1.8.0` is unverified from this seat.** The tag's *peeled target*
(the commit SHA it actually points at) cannot be resolved without `git cat-file -p v1.8.0`,
and `gh` is also unavailable (release-due.md:45-95). What is in hand:

- `lib/wurk/version.rb:4` reads `Wurk::VERSION = '1.8.0'`; `CHANGELOG.md:7` carries
  `## [1.8.0] - 2026-10-05` as the dated heading. Together these are the in-tree signals
  that a v1.8.0 release commit exists on `main`; whether the tag is placed *at* that commit
  is what the next seat (with `git`) must verify.
- `.git/refs/remotes/origin/main` resolves to
  `261b9fd92c77334704873ea2db726bd5089d61b2`, which differs from the tag's stored SHA above.
  Whether `origin/main` is past, equal to, or behind the v1.8.0 release commit cannot be
  decided without peeling the tag.

**A correctly placed release tag remains valid while `origin/main` advances.** The release
PR bumps `lib/wurk/version.rb` to the next version, merges to `main`, and `release.yml`
publishes the gem and only then cuts the tag (RELEASE.md, "The one rule"). After the tag
is cut, `origin/main` continues to receive new commits in the normal course of
development; that is the steady post-release state, not an indicator that intervening
commits are "unreleased". Calling that state "stray" or claiming "shipping commits that
have not been released" (as the prior draft of this section did) would falsely flag a
normal post-release tree as overdue, and the SHA difference between tag and `origin/main`
does not establish that the v1.8.0 release commit is even an ancestor of `origin/main`
without peeling the tag.

**The path-filtered window's emptiness is not decided by a SHA difference.** The Decide
section's filter (release-due.md:11) restricts the window to `lib/**/*.rb`, `lib/**/*.lua`,
`app/**/*.rb`, `config/**`, `exe/*`, `frontend/src/**`, and `wurk.gemspec`. Commits that
touch only excluded paths (e.g. `CHANGELOG.md`, `docs/**`, prose `*.md`) leave the *filtered*
window empty even when the unfiltered
`v1.8.0..origin/main` revision walk is non-empty. A difference between the tag SHA and
`origin/main` therefore does not establish that the filtered window is non-empty.

### Decision-table action (release-due.md:19-25)

Action: **blocked — pending the filtered `git log` and the oldest commit's date.** Reasoning
per row:

- Row 1 (`empty`) — **not decidable from this seat**: the path-filtered window's emptiness
  cannot be inferred from a SHA difference (see "v1.8.0 disposition" above). The Decide
  command at release-due.md:11 is the only source that resolves this row, and the runner
  refuses `git` (release-due.md:65). Recorded as "not applied, unverifiable".
- Row 2 (`Wurk::VERSION` already ahead of `$last`) — **does not apply**:
  `Wurk::VERSION = '1.8.0'` (lib/wurk/version.rb:4) equals `$last = v1.8.0`
  (.git/refs/tags/v1.8.0), not ahead.
- Row 3 (the oldest shipping commit is under 24 h old) — **not decidable from this seat**:
  `git log --format='%h %cI %s' "$last"..origin/main -- …` cannot run from this seat
  (release-due.md:71-75), so no commit date is reachable. Recorded as "not applied,
  unverifiable".
- Row 4 (Breaking change under `## [Unreleased]`) — **does not apply**: CHANGELOG.md:5-6
  shows `## [Unreleased]` is the heading on line 5 with no `###` subsection following it
  (line 6 is blank, line 7 is the dated `## [1.8.0]` heading), so there is no Breaking change
  to block the ask.
- Row 5 (`otherwise`) — **not applied**: row 1 and row 3 are both unverifiable from this
  seat, and either could be the controlling row if the next seat can run `git log`. The
  table instructs the seat to commit to one row only when the others are ruled out; here,
  two rows are not ruled out, so row 5 is not the resulting action. The action is **blocked
  pending the filtered log and commit dates** rather than a release ask.

### Handoff

The verifier (the seat that can run `git log v1.8.0..origin/main -- …` against the file
paths in release-due.md:11) must:

1. Peel `refs/tags/v1.8.0` (`git cat-file -p v1.8.0`) and confirm the peeled target is the
   commit that introduces `## [1.8.0] - 2026-10-05` in `CHANGELOG.md:7`. If it is not, the
   tag is misplaced; surface that as a finding rather than continuing.
2. Run the filtered `git log` from release-due.md:11 and decide row 1 (empty vs not) from
   that output. SHA difference alone does not settle this row (see "v1.8.0 disposition"
   above).
3. Read the oldest filtered commit's date; if it is under 24 h old, row 3 supersedes and
   no release ask is filed yet.
4. Pick `<next>` per release-due.md:27-28 from the actual commit subjects (`feat` → minor,
   else patch; `### Added` under `[Unreleased]` was not present here so its cue is absent).
5. Confirm there is no open `Release …` ask already (release-due.md:41).
