# Brief: monthly improvement

Fired every Monday by `schedules: improve` in `.dz/maintainer/maintainer.yml`. **Act only on the first
Monday of the month (UTC day 1-7); on any other Monday stop here and do nothing.**

```bash
[ "$(date -u +%d)" -le 7 ] || { echo "not the first Monday of the month: improve does nothing"; exit 0; }
```

Wurk is maintained by agents only. Once a month, leave it measurably better and one step ahead of
the next Sidekiq, Ruby and Rails release. Read `CLAUDE.md` first: its three pillars (100% drop-in,
free, measured), its *Never* list and its Testing rules (real Redis, parity tests are oracles, the
90% line + branch coverage gate) bind every change. `non_goals` in the policy file are off limits.

## 1. Read what CI already knows

The `health` checkup owns a red `main`, a release that did not publish and a stuck Dependabot PR.
If it has an ask open for something, leave it to that ask. This pass reads the lanes `health` does
not grade:

| Signal | Command | Healthy |
|---|---|---|
| support window (nightly `compat` legs: Ruby floor, oldest Rails, Valkey) | `gh run list --workflow test.yml --event schedule --limit 5 --json conclusion,url,createdAt` | last runs `success` |
| ecosystem suites + `sidekiq release watcher` (weekly) | `gh run list --workflow ecosystem.yml --event schedule --limit 3 --json conclusion,url,createdAt` | `success` |
| Redis topologies (Valkey 8, TLS, ACL, Sentinel) | `gh run list --workflow topology.yml --branch main --limit 3 --json conclusion,url,createdAt` | `success` |
| parity pin vs upstream Sidekiq | `curl -fsS https://rubygems.org/api/v1/versions/sidekiq.json \| jq -r '.[0:5][] \| "\(.number) \(.created_at)"'` against the `date:` in `test/parity/.sidekiq_sha` (Sidekiq publishes no GitHub Releases, only tags and gems) | no release since the pin's date |

Read the failing job's log before deciding anything. A red watcher whose log says
`DEVELOPERZ_API_KEY missing` is a secret only the owner can add: escalate once, never remove the
watcher or turn the check back into a green skip.

## 2. Pick at most three improvements, in this order

1. **A break the signals found**: a red compat leg, ecosystem suite or topology run. Fix the cause
   in wurk. If the break is upstream (a gem or Redis release), open one issue linking the upstream
   report instead of a shim (`CLAUDE.md`: no backwards-compat shims).
2. **Upstream drift**: a Sidekiq release changed documented behaviour. Update `docs/target/sidekiq-{free,pro,ent}.md`,
   the parity oracle and the implementation together; move `test/parity/.sidekiq_sha` only after
   reviewing the upstream diff and running `bin/rake test:parity`. A new Ruby or Rails release not yet
   in the `compat` matrix gets a leg there. Raising the gemspec Ruby floor or dropping a Rails series
   is a breaking change (see 3).
3. **Dependency majors Dependabot can't land**: a major that failed CI or was closed, the frontend
   majors that need code changes. Full `bin/check full` plus the frontend's `bun run test` and
   `bun run lint`.
4. **Speed**, pillar 3. Wurk is still behind stock Sidekiq on `noop` and on boot (`docs/benchmarks.md`,
   *Why wurk is still behind on `noop`*): fewer Redis commands per job (`bin/rake bench:command_count`)
   and less per-job allocation are the levers. A change counts only with numbers: `bin/rake bench` on
   `main` and on the branch, best of 3 per side, compared with `bin/bench-compare base.txt head.txt`,
   then confirmed by the PR's own `bench vs base` comment. A claim against Sidekiq needs paired
   `bin/rake bench:vs_sidekiq` runs and an updated `docs/benchmarks.md`; never a "faster" claim the
   doc's numbers don't support. Wire compatibility beats any speedup.
5. **Correctness**: open issues labelled `bug` or `sidekiq-parity`; pending conformance cases
   (`docs/conformance.md`) that now have an oracle; entries in `docs/idea/parity-divergences.md` that
   no longer need to diverge; a gem `docs/idea/14-ecosystem-compat.md` tracks but `bin/rake test:ecosystem`
   does not run yet. Every fix starts with a test that fails on `main`, against real Redis.
6. **Hidden failures**: a `rescue` that swallows, `|| true`, `2>/dev/null`, a `continue-on-error`, a
   test that skips in CI. Make it fail, or handle it visibly (log, `::error::`, a test that pins it).
   A documented, deliberate fallback stays; give it a reason comment if it has none.
7. **Docs drift**: `README.md`, `docs/site/llms.txt`, `docs/*.md` and `CLAUDE.md` still match the code.
   `.dz/schedules/docs-drift.md` lists which guards exist and what they don't cover.
8. **Simplification**: dead code (the tests that `skip` an "unreachable" branch name candidates),
   duplicated logic, slow or flaky tests. Coverage must stay at or above 90% line and branch.

## 3. Ship

One pull request per improvement, small and reviewable, titled with what it changes. `bin/check`
passes locally first (it needs Redis). The body gives the evidence: the failing run or log, the
before/after `bin/bench-compare` table, or the test that failed before the fix. User-visible changes
get a CHANGELOG `## [Unreleased]` entry.

Never bump `lib/wurk/version.rb` here: the `release-due` checkup decides releases. A breaking change
(`escalate.ask_before_acting: [breaking_change]`) is never merged by this lane: open the PR or the
issue, explain the trade-off and leave it for the owner.

Before opening anything, check that no open PR or issue already covers it. If nothing is worth
changing this month, do nothing: no empty PRs, no churn.
