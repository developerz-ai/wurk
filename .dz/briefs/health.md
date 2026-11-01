# Brief: is the project healthy?

Daily `schedules: health` checkup; failures no issue or PR announces.

## Rows

- `main`
- `release`
- `rubygems`
- `github-release`
- `deploy`
- `served-version`
- `lanes`
- `dependabot`

| Signal | Command | Healthy |
|---|---|---|
| `main` is green | `bash bin/health-check main` | `executed`; `duplicate-skipped` and `evidence unavailable` file no ask |
| the last release published | `bash bin/health-check release` | `success <sha> <url>` (published and live on RubyGems), or `no-op <sha>` (proceed=false) |
| RubyGems serves `Wurk::VERSION` | `bash bin/health-check rubygems` | HTTP 200, or a release run is in flight |
| the GitHub Release carries the gem | `bash bin/health-check github-release` | Latest carries `.gem`; author is not `developerz-ai[bot]` |
| the demo deployed | `bash bin/health-check deploy` | `success` with a `sha-<7>` tag from `resolve built commit` (pushed, not served) |
| the demo serves the checkout version | `bash bin/health-check served-version` | `success: the demo serves <version>`; mismatch is Unhealthy; unreadable version is `verdict unknown` (see Demo grading) |
| topology and ecosystem lanes | `bash bin/health-check lanes` | Both `executed`; `duplicate-skipped` and `evidence unavailable` file no ask |
| Dependabot is not stuck | `bash bin/health-check dependabot` | Red past budget is stuck except Docker cases below; unknown/awaiting-pin files no ask | 

Run from repository root via Bash. Helpers only read and grade.

**Push grading.** Main/lanes read jobs and gated steps. Successful detect + every gated job successful + every gated step skipped (except runner setup/teardown) means duplicate-skipped; a non-skipped gated step means executed. Missing jobs/no gated job means evidence unavailable, not verified green. Exclude ecosystem's sidekiq release watcher. Failed runs grade on conclusion. Failed/non-array run reads are unknown; readable empty arrays print no run, not unknown or Unhealthy.

**Release grading.** Read version AT newest main commit touching lib/wurk/version.rb; select its primary push with --branch main --event push --commit; refuse other headSha. Unreadable version/run/jobs is unknown. Null conclusion is in flight. Successful preflight + skipped release is no-op (proceed=false: already published); failed preflight is not a no-op. Demo needs preflight and release. Grade conclusion; cross-check green with https://rubygems.org/api/v2/rubygems/wurk/versions/<version>.json (RELEASE.md's *Verifying a release actually shipped*). HTTP 200 is success; 404 is missing (RubyGems row defers while the bound run is in flight). Unknown/mismatched runs, transport failures, HTTP 000/other statuses are unknown. Curl captures status without -f, with --max-time 5.
Supported main-branch workflow_dispatch retries are valid hand-dispatched retries, not primary main-push publication attempts; off-main rejection alone must not trigger a publication alarm; recovery remains filing-only.
Latest GitHub Release requires readable author/assets: bot author OR zero assets is gem-less.

**Demo grading.** Read the build job's full log, only field 2 resolve built commit. Require a whole sha-[0-9a-f]{7} token, not an 8-hex prefix or another step's tag. Missing tag is Unhealthy; unreadable jobs/log is unknown; otherwise grade conclusion even with a tag. Pushed tag is not served version. Read-only https://wurk.demo.developerz.ai/wurk/api/meta compares checkout lib/wurk/version.rb: HTTP 200, exactly one JSON object and usable matching version is healthy; mismatch is Unhealthy; transport/non-200/malformed/missing version is unknown. Check whole JSON stream and jq exit status, including trailing garbage.

**Dependabot grading.** Open PRs only; branch ecosystem wins over title fallback. Budgets (interval + bundler cooldown + 7d): bundler 28d, bun 14d, github-actions/docker 37d. Age is createdAt, strictly past budget; updatedAt is reported only. Roll up StatusContext state or CheckRun conclusion; unfinished is PENDING. FAILURE/ERROR/TIMED_OUT/CANCELLED/ACTION_REQUIRED/STALE/STARTUP_FAILURE outrank pending; otherwise SUCCESS (including empty/skipped/neutral). Ignore non-object entries. Report ecosystem counts/states and each PR's branch, headRefOid, updatedAt (unknown if absent). Young red or old green/pending is not stuck.
Docker discriminator FIRST reads test.yml runs at headRefOid, jobs, then only test + coverage (latest ruby/rails) failed log. Unreadable evidence/no named failing test is unknown. Only toolchain_pins_test.rb failing + clean siblings + EVERY red rollup entry naming a failed job of that run permits awaiting matching pin edits (no ask); external red statuses or bench/topology failures keep stuck.
ONLY a readable list with NO failed run allows waiting-on-us fallback for a past-budget red Docker bun-pin-shaped title (slash dependency or grouped updates). Read five pin sites at headRefOid: Dockerfile, mise.toml, docs/deployment.md, test.yml, release.yml. Check each exit status even with a nonempty error body. Unreadable pins: unknown/no ask; mismatch: waiting on us, push matching bun pin edits; agreeing pins: stuck. Never infer mismatch from title. No gate bypass or merge permission; platform owns stalled-PR timing, no second age-based ping/close here.

For each unhealthy signal, file one ask unless an open issue already names it. Filing an ask
requires FIRST running, exactly, `gh api --paginate "repos/developerz-ai/wurk/issues?state=open" | jq -r '.[] | select(.pull_request == null) | .title'`
If a returned title equals the signal's title exactly, the ask exists — never file a second ask while one with this title is open. Titles are stable, matched by exact equality; nothing run-specific (sha, run URL, version, PR age) may appear in one — those live in the body. The stable titles are: row 8 files `main is red`; row 9 files `release did not publish`;
row 10 files `RubyGems does not serve Wurk::VERSION` (the constant's name, never its value); row 11 files `GitHub Release is gem-less`; row 12 files `demo deploy failed` for a failed deploy-demo conclusion line, even when it includes `tagged sha-<7>`; the tag cannot override failure. Row 12 files `demo frozen: no sha-<7> image tag` only for the missing-tag verdict; the demo served-version row files `demo serves a different version than the checkout`;
row 14 files per workflow so the two lanes stay distinguishable — `topology.yml is red` and `ecosystem.yml is red`; row 15 files one ask per stuck PR titled `Dependabot is stuck on #<n>`, and one ask per waiting-on-us docker bump titled `Docker bump #<n> is waiting on us` — filed only when the head-pins read has verified the mismatch still outstanding: the owner is the maintainer agent, next action pushing the matching bun pin edits to the dependabot branch. A waiting-shaped PR whose pin-site reads fail grades `verdict unknown` and files no ask, and one whose pins agree takes the stuck ask. A `duplicate-skipped` push files no ask and an `evidence unavailable` verdict files no ask either.
A `no run: <workflow> has no matching run` line files NO ask: it is never filed under a row's Unhealthy titles (`main is red`, `demo frozen: ...`,
`topology.yml is red`, …), and it is not `verdict unknown` either. The same holds for the
`verdict unknown ... not readable` lines: an unreadable list files no ask. Only a line that names a defect files one
ask, under the stable title its row owns: an `Unhealthy:` verdict, or a failed run's own conclusion
line — rows 8, 9, 12 and 14 print conclusion, headSha and run URL without an `Unhealthy:` prefix; that line is the
trigger `main is red`, `release did not publish`, `demo deploy failed`, `topology.yml is red` and
`ecosystem.yml is red` are filed from. Everything else a row can print — a readable `success`, `duplicate-skipped`,
`evidence unavailable`, `in flight`, `no-op` — is not a defect and files nothing. The body carries
the command, its output, the run URL, the headSha, the version and the PR age.
A red `main` comes first: nothing releases from it. The checkup lane's ONLY admissible
response to a red `main` or a failed release is the filing rule above: file one deduped ask for a
maintainer. Recovery is a maintainer's manual runbook, `RELEASE.md`'s *If a release fails*. The
ask points there — this lane never executes it. For a gem-less release the ask points at
*Recovering a gem-less release*: `gh release delete vX.Y.Z --cleanup-tag --yes`, then
`git fetch --prune-tags`, then CI re-cuts the tag from the version bump (maintainer-run only).
That cleanup is sanctioned. From this lane, never re-tag over an existing `vX.Y.Z` (force-move),
never `gem push` instead of CI, and never republish a version already on RubyGems; only the
version CI published may be published for that release. RELEASE.md's *Break-glass manual publish*
when CI is unavailable is not re-tagging: the gem has already shipped. The checkup never deletes
a tag, re-runs a publish or pushes a gem.
