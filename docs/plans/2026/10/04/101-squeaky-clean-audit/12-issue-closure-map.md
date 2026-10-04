# 12 — Issue closure map (all open issues + PRs → slice)

> Part of [`overview.md`](overview.md). Snapshot 2026-10-04, `origin/main` @ `8126e42`: 13 open issues, 1 open PR. Executor: after closing, comment with evidence (PR link) per CONTRIBUTING; never close without a merged fix or a recorded human decision.

## Issues

| Issue | Title (short) | State | Slice | PR batch | Human? |
|---|---|---|---|---|---|
| #541 | bun.lock reconcile push → no required checks | valid | [`05`](05-ci-gates.md) C5/C6 | B1 CI gates | no |
| #470 | dependabot lockfile fix leaves PR red | **dup of #541** | 05 C6 | B1 | no — close as dup w/ link |
| #469 | parity + lint satisfied by skipping | valid | 05 C4 | B1 | no |
| #471 | rubocop release reddens main | valid | [`07`](07-lint.md) | B2 lint pin | U4 decision |
| #477 | PredicateMethod config vs 35 disables | valid | 07 | B3 | U5 re-triage |
| #522 | timing-sensitive tests (WebSearch, WebExtensions left) | partial (#535 fixed limiter) | [`08`](08-test-hygiene.md) | B4 test hygiene | no |
| #486 | SimpleJob TODO | valid | 08 | B4 | no |
| #491 | `rake release` / `release:full` bypass | valid | [`06`](06-release-lane.md) | B5 release lane | no |
| #482 | commit demo/Gemfile.lock | valid (not truly HITL) | 06 | B5 | no |
| #488 | maintainer.yml stale claims | partial (#501 merged) | below | B6 policy doc (after B1) | no |
| #537 | honour `:redis_idle_timeout` | valid, **frozen** by #530 rule 6 | below | — | U6 first |
| #530 | delivery-benchmark pre-registration | protocol tracker; deadline elapsed | [`11`](11-human-actions.md) U6 | — | yes |
| #441 | AlternativeTo listing | valid, off-repo | 11 U7 | — | yes |

## Open PRs

| PR | State | Action |
|---|---|---|
| #527 vitest 4.1.11 → 5.0.0 | BLOCKED since 2026-09-10 (head `a80803db` has no required checks = #541); first commit failed `test + coverage` + `frontend (vitest)`; major → no auto-merge | After B1: `@dependabot recreate`; confirms #541 fix (three contexts on new head). Then fix vitest 5 compat in `frontend/` (config + any API breaks) or close w/ reason + ignore rule in `.github/dependabot.yml`. |

## #488 — remaining scope
- `.dz/maintainer/maintainer.yml:70-73`: "inert until dz#1249 and dz#1530 close" false → dated checkable statement (live as of developerz.ai `b4cfe94d76e9`, 2026-09-14; `lanes.generated.ts:121`).
- `:117` cites `(.maintainer.yml:10-14)` → path moved to `.dz/maintainer/maintainer.yml`.
- `:95` "none of the three required checks can wedge a PR" → false until B1 lands; rewrite after B1 to describe the mechanism.
- Also stale: "bin/check refuses without Redis on 127.0.0.1:6379" (since #538 probes `REDIS_URL`).
- Test: `ruby -ryaml -e 'YAML.load_file(".dz/maintainer/maintainer.yml")'`; `bin/check`.
- `scout-backlog-drain.ts:18-21` fix lives in developerz.ai repo — out of scope.

## #537 — once U6 releases it
- `RedisPool#with` (`lib/wurk/redis_pool.rb`): per-connection last-checkin timestamp; reaper thread (only when `redis_idle_timeout` set; no timer when nil) closes idle **checked-in** conns via `safe_close`; `#available` reflects reaping. Must be per-fork (start in child after pool creation).
- Coordinate with [`02`](02-core-runtime.md) K11 (same file) — land K11 first.
- Real-Redis tests: idle > timeout reaped; < timeout kept; checked-out kept. Update `docs/configuration.md:147,832`; `configuration.rb:49`.

## New issues to file (from this audit)
File one GitHub issue per P0/P1 finding group so progress is visible and auto-linkable. Suggested grouping (labels: `bug`, `area/backend`, `priority/p0|p1`, `afk`):

| New issue | Covers |
|---|---|
| error_handlers never see job failures | K2 (R1) |
| scheduler thread dies on Redis error | K1 + thread-loop audit |
| retry delay ignores Duration; AJ options overridden | K3, K4 |
| reaper can reclaim a live worker's job | K5 |
| reliable scheduler wedged by one bad member | K6 |
| rails runner/generate forks swarm | K7 |
| Sentinel `name:` swallowed; capsule pool thread-local | K8, K9 |
| batch callback correctness (early fire, -1, lost, invalidate, nesting) | E3, E4, E15–E18, E25–E27, E29, E30 |
| plaintext secret on interrupt re-push | E5 |
| periodic jobs ignore sidekiq_options; one loop starves cron | E6, E28 |
| API iteration skips + scan enumerator + kill_all default | E1, E2, E7, E31 |
| metrics key format + Query class | E8, E9 |
| missing Sidekiq aliases + require shims | E10, E12 |
| dashboard: Sidekiq::Web auth bypass | W1 |
| dashboard: SSE thread starvation | W2 |
| CI path filters + release main guard + dependabot bun | C1–C3, C5, C7 |
| migration proof: real Pro/Ent dump, mixed fleet, drain cutover doc | R2–R4 |
| ecosystem doc truth + harnesses | R5 |
| many-queue fetch cost; cgroup fork count | R8, R9 |
| soak/chaos harness + published numbers | R11 |
| metrics exporter + child liveness | R14 |
| infra: runner watchdog cadence (infra repo) | X1, X2 |

## Done when
- `gh issue list --state open` shows only issues created by this audit that are in progress, plus human-gated ones with a recorded decision date.
- #527 resolved.
