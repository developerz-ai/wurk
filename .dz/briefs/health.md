# Brief: is the project healthy?

Daily checkup via `schedules: health` in `.dz/maintainer/maintainer.yml`; failures no issue or PR announces.

| Signal | Command | Healthy |
|---|---|---|
| `main` is green | `bash bin/health-check main` | `executed` (the gated steps ran); `duplicate-skipped` and `evidence unavailable` file no ask |
| the last release published | `bash bin/health-check release` | `success <sha> <url>` — the run published `Wurk::VERSION` and the gem is live on RubyGems — or a named `no-op <sha>` (proceed=false, nothing owed) |
| RubyGems serves `Wurk::VERSION` | `bash bin/health-check rubygems` — RELEASE.md's canonical availability probe (*Verifying a release actually shipped*), version read at its commit | HTTP 200, or a release run is in flight |
| the GitHub Release carries the gem | `bash bin/health-check github-release` | the Latest GitHub Release carries the `.gem` and its author is not `developerz-ai[bot]` |
| the demo deployed | `bash bin/health-check deploy` | `success`, and a `sha-<7>` image tag the `resolve built commit` step wrote (this proves the pushed tag, not the served version) |
| the demo serves the checkout version | `bash bin/health-check served-version` | `success: the demo serves <version>`; a mismatch is Unhealthy, and a transport failure, a non-200 response, a body that is not a single JSON object (trailing garbage included) or a missing `version` key is `verdict unknown` |
| topology and ecosystem lanes | `bash bin/health-check lanes` | `executed` on both (the gated steps ran); `duplicate-skipped` and `evidence unavailable` file no ask |
| Dependabot is not stuck | `bash bin/health-check dependabot` | Summary and per-PR evidence; red past budget is stuck except verified Docker cases below; unknown and awaiting-pin outcomes file no ask | 

Run each command from the repository root via Bash. Helpers only read and grade.

**Push grading.** Main/lanes read jobs and gated steps. Successful detect + every gated job successful + every gated step skipped (except runner setup/teardown) means duplicate-skipped; a non-skipped gated step means executed. Missing jobs/no gated job means evidence unavailable, not verified green. Exclude ecosystem's sidekiq release watcher. Failed runs grade on conclusion. Failed/non-array run reads are unknown; readable empty arrays print no run, not unknown or Unhealthy.

**Release grading.** Resolve newest main commit touching lib/wurk/version.rb, read version AT that commit, select its primary push with --branch main --event push --commit, and refuse a different headSha. Unreadable version/run/jobs is unknown. Null conclusion is in flight. Successful preflight + skipped release is no-op (proceed=false: already published); failed preflight is not a no-op. Demo needs preflight and release. Otherwise grade conclusion, cross-checking green with the canonical probe: https://rubygems.org/api/v2/rubygems/wurk/versions/<version>.json (RELEASE.md's *Verifying a release actually shipped*). HTTP 200 is success; HTTP 404 is missing, except row 10 defers while the bound run is in flight. Unknown/mismatched runs remain unknown. Transport failures, HTTP 000 and other statuses are unknown. Probe curls capture status without -f and bound requests with --max-time 5.
Supported main-branch workflow_dispatch retries are valid hand-dispatched retries, not primary main-push publication attempts; off-main rejection alone must not trigger a publication alarm; recovery remains filing-only.
Latest GitHub Release requires readable author/assets: bot author OR zero assets is gem-less.

**Demo grading.** Read the build job's full log, only field 2 resolve built commit. Require a whole sha-[0-9a-f]{7} token, not an 8-hex prefix or another step's tag. Missing tag is Unhealthy; unreadable jobs/log is unknown; otherwise grade conclusion even with a tag. Pushed tag is not served version. The public read-only https://wurk.demo.developerz.ai/wurk/api/meta probe compares checkout lib/wurk/version.rb. HTTP 200 with exactly one JSON object and usable matching version is healthy, differing version is Unhealthy; transport/non-200/malformed/missing version is unknown. Validate whole JSON stream and jq exit status, including trailing garbage.

**Dependabot grading.** Open PRs only; branch ecosystem wins over title fallback. Budgets (interval + bundler cooldown + 7d): bundler 28d, bun 14d, github-actions/docker 37d. Age is createdAt, strictly past budget; updatedAt is reported only. Roll up StatusContext state or CheckRun conclusion; unfinished is PENDING. FAILURE/ERROR/TIMED_OUT/CANCELLED/ACTION_REQUIRED/STALE/STARTUP_FAILURE outrank pending; otherwise SUCCESS (including empty/skipped/neutral). Ignore non-object entries. Report ecosystem counts/states and each PR's branch, headRefOid, updatedAt (unknown if absent). Young red or old green/pending is not stuck.
Docker discriminator FIRST reads test.yml runs at headRefOid, jobs, then only test + coverage (latest ruby/rails) failed log. Unreadable evidence/no named failing test is unknown. Only toolchain_pins_test.rb failing + clean siblings + EVERY red rollup entry naming a failed job of that run permits awaiting matching pin edits (no ask); external red statuses or bench/topology failures keep stuck.
ONLY a readable list with NO failed run allows waiting-on-us fallback for a past-budget red Docker bun-pin-shaped title (slash dependency or grouped updates). Read five pin sites at headRefOid: Dockerfile, mise.toml, docs/deployment.md, test.yml, release.yml. Check each exit status even with a nonempty error body. Unreadable pins: unknown/no ask; mismatch: waiting on us, push matching bun pin edits; agreeing pins: stuck. Never infer mismatch from title. No gate bypass or merge permission; platform owns stalled-PR timing, no second age-based ping/close here.

For each unhealthy signal, file one ask unless an open issue already names it. Filing an ask
requires FIRST running, exactly, `gh api --paginate "repos/developerz-ai/wurk/issues?state=open" | jq -r '.[] | select(.pull_request == null) | .title'`
If any returned title equals the signal's title exactly, the ask already
exists — never file a second ask while one with this title is open. Titles are stable, matched by exact equality;
nothing that changes run to run (sha, run URL, version, PR age) may appear in it — those
live in the body. The stable titles are: row 8 files `main is red`; row 9 files
`release did not publish`; row 10 files
`RubyGems does not serve Wurk::VERSION` (the constant's name, never its value); row 11 files
`GitHub Release is gem-less`; row 12 files `demo deploy failed` for a failed deploy-demo
conclusion line, even when it includes `tagged sha-<7>`; the tag cannot override failure.
Row 12 files `demo frozen: no sha-<7> image tag` only for the missing-tag verdict; the demo
served-version row files `demo serves a different version than the checkout`; row 14 files per
workflow so the two lanes stay
distinguishable — `topology.yml is red` and `ecosystem.yml is red`; row 15 files
one ask per stuck PR titled `Dependabot is stuck on #<n>`, and one ask per
waiting-on-us docker bump titled `Docker bump #<n> is waiting on us` — filed only when the head-pins read has verified the mismatch still outstanding: the owner is the maintainer agent
and the next action is pushing the matching bun pin edits to the dependabot branch. A waiting-shaped PR
whose pin-site reads fail grades `verdict unknown` and files no ask, and one whose pins already
agree takes the stuck ask instead. A `duplicate-skipped`
push files no ask
and an `evidence unavailable` verdict files no ask either.
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
ask points there — this lane never executes it. For a gem-less release the ask points at that
runbook's *Recovering a gem-less release*: `gh release delete vX.Y.Z --cleanup-tag --yes`, then
`git fetch --prune-tags`, then let CI re-cut the tag from the version bump — all maintainer-run
steps, never commands this lane runs. That cleanup is the sanctioned path, not a workaround — from
this lane, never manually re-tag over an existing `vX.Y.Z` (force-moving a tag to a different
commit), never `gem push` from a workstation as a replacement for the CI publish lane, and never
force a version already on RubyGems down the publish lane a second time; the only version number
that may be published for a given release is the one CI published. Break-glass hand-cutting a
release when CI is unavailable, as RELEASE.md's *Break-glass manual publish* prescribes, is not
re-tagging or force-moving — a maintainer runs it only because the gem has already shipped and the
lane can no longer act. Beyond pointing at that sanctioned cleanup in the ask, the checkup never
deletes a tag, re-runs a publish or pushes a gem.
