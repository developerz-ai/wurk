# Evidence-driven improvement sweep (adopters · drop-in · perf · algorithms · memory)

## Goal
Make Wurk better where real use says it hurts: fix what the 5 adopter apps had to work around, close the gaps that block treasury's Sidekiq 7.3 + Pro + Ent swap, and cut measured cost in the hot path, boot/load time, O(N) Redis work and memory — every claim backed by a test, an oracle or a named bench.

## Context
- Ruby ≥ 3.2, Redis ≥ 7 (Lua), Rails engine + SolidJS/bun dashboard, Minitest on real Redis. Root `CLAUDE.md` invariants bind every slice: Redis keys / job JSON / score formats never move; `Sidekiq::*` aliases never break; per-fork Redis pool; boot ordering; no worktrees; never DB 0 / `FLUSHALL` / `SCRIPT FLUSH`.
- Maps: `lib/CLAUDE.md` (who owns what), `test/CLAUDE.md` (layers), `.github/CLAUDE.md` (CI, bench, release), `frontend/CLAUDE.md`. Spec: `docs/target/sidekiq-{free,pro,ent}.md`. Intentional divergences: `docs/idea/parity-divergences.md`.
- Sweeps (2026-11-10, v1.11.1 @ `f6f509e`, read-only): (1) 5 adopter apps — config, git history, logs, deploy, Sentry (tesote org, 30 d); (2) treasury Sidekiq surface vs Wurk; (3) core runtime; (4) dashboard / HTTP API / ecosystem / docs / CI; (5) algorithms + memory. Line refs are as of `f6f509e` — re-locate by symbol if moved.
- Honest limits: sweeps 3–5 read code, ran no tests/benches/Redis. Rows marked "inferred"/"suspect" need the reproducing test first. Worst-case numbers in [`07`](07-algorithms.md) are arithmetic. Timings in [`06`](06-perf-hot-path-boot.md) were taken on a loaded host.
- Healthy baseline (don't redo): 0 open issues; no TODO/FIXME in `lib/`; coverage ~98/92; adopter logs show no Wurk-originated errors (no NOSCRIPT / reclaim / heartbeat noise); Sentry has no live Wurk defect beyond SALES-APP-21 (fixed in 1.11.1); config docs match code; no forbidden "faster" claims; ACK piggyback, leader CAS, cron fire CAS, unique release verified sound.
- Adopters: `tesote/sales`, `tesote/tesote.com`, `tesote/gringotts-wizarding-bank`, `hiscore/hiscore.ro`, `developerz-ai/legaldiligencemedellin.com` (all under `~/workspace`). `tesote/treasury` = future target, **read-only**. `tesote/sidekiq` = licensed Pro/Ent source: reference only, copy nothing.
- Reference patterns: boot WARN → `lib/wurk/boot_checks.rb:64-83`; preflight row → `lib/wurk/preflight/checks.rb:183-189`; single-read paging → `lib/wurk/web/paginator.rb:12-46`; atomic Lua move → `lib/wurk/lua.rb:163-170`; ecosystem harness → `test/ecosystem/README.md`; bench output format → `bench/fetch_100_queues.rb` + `bin/bench-compare`.
- Execution: hive rules (`.claude/commands/feature.md`) — ≤4 agents per wave, only the coordinator spawns, disjoint file sets, one checkout. One PR in flight at a time (build → PR → merged → pull → clean tree → next), ≤100 files. Merge bot merges on green: review + soak before push. `lib/` edits → `bin/repin-anchors` on the PR's own tree. Release = merged `lib/wurk/version.rb` bump only (`RELEASE.md`).

## Headline (what the evidence says matters most)
| # | Finding | Slice |
|---|---|---|
| 1 | **Live in tesote.com:** `unique_for:` with no `unique!` → dedup never ran; Wurk gives no warning | [`14`](14-adopter-tesote-com.md) S1, [`03`](03-boot-guards-preflight.md) G1 |
| 2 | Poison-pill check runs after the job is back on the public queue → 4th run + death handlers fire mid-run when a worker is parked | [`02`](02-reclaim-correctness.md) R1 |
| 3 | `main` red since 2026-11-07 (Python 3.9 leg) | [`01`](01-ci-green-doc-truth.md) C1 |
| 4 | Worker boot path ≠ web/test path → prod crash loops in 5/5 adopters, CI green each time | [`03`](03-boot-guards-preflight.md) G10 |
| 5 | Treasury swap is not one line: `bundle exec sidekiq` missing, shim floats on `main`, `failed_at` read as seconds, `connection_pool` pin | [`04`](04-drop-in-surface.md) D1–D2, [`03`](03-boot-guards-preflight.md) G11–G12 |
| 6 | `require "wurk"` loads everything everywhere (404 features, ~15 MB, no `autoload`); noop CPU gap vs Sidekiq never decomposed | [`06`](06-perf-hot-path-boot.md) L0–L4, P1 |
| 7 | Deep dashboard pages cost a Redis round-trip per skipped row; fast-delete Lua copies whole queues; reaper SCANs the keyspace every 60 s + per child boot | [`07`](07-algorithms.md) A1, A3, A4 |
| 8 | No RSS/PSS measurement, recycle path untested, no pre-fork compaction on Ruby 3.2 / railtie path, no allocator guidance | [`08`](08-memory.md) M0–M4 |
| 9 | No committed soak/chaos or mixed-fleet proof | [`12`](12-proof-harness.md) T1–T2 |
| 10 | 4 of 5 adopters probe workers badly or not at all; none scrapes `/metrics` | [`11`](11-observability-ops.md), [`19`](19-infra-tesote.md), [`20`](20-infra-developerz.md) |

## Plan files (execute in order within a wave)
1. [`01-ci-green-doc-truth.md`](01-ci-green-doc-truth.md) — red `main`, contradicting docs, stale blockers.
2. [`02-reclaim-correctness.md`](02-reclaim-correctness.md) — poison-before-push, parent reclaim by exact key, boot SCAN behind the lock, key-parse property test.
3. [`03-boot-guards-preflight.md`](03-boot-guards-preflight.md) — G1–G15: silent misconfig → WARN/ERROR; `wurk boot-check`; `preflight --app` source scans.
4. [`04-drop-in-surface.md`](04-drop-in-surface.md) — `sidekiq` executable, pinned shim, `/stats` routes, proctitle, untested surfaces, ecosystem pins.
5. [`05-errors-and-test-mode.md`](05-errors-and-test-mode.md) — `Rails.error` oracle, Sentry exclusions, idempotency doc, `Testing` gaps.
6. [`06-perf-hot-path-boot.md`](06-perf-hot-path-boot.md) — CPU-per-job decomposition, fetch allocations, heartbeat, **lazy-loading tiers**.
7. [`07-algorithms.md`](07-algorithms.md) — A1–A19: O(N) commands, N+1 round-trips, new benches.
8. [`08-memory.md`](08-memory.md) — RSS/PSS bench, watchdog tests, pre-fork compaction, allocator guidance, bounded caches, Redis bytes.
9. [`09-dashboard.md`](09-dashboard.md) — CSP, sub-path, plain-HTTP 403, payload filter, health notices, bundle weight, Pro gaps.
10. [`10-http-api-clients.md`](10-http-api-clients.md) — OpenAPI + parity test, Python integration, operator endpoints, job-format doc.
11. [`11-observability-ops.md`](11-observability-ops.md) — missing metrics, systemd/k8s/capistrano kit, sizing table, periodic toggles, upgrade notes.
12. [`12-proof-harness.md`](12-proof-harness.md) — soak/chaos with jid ledger, mixed fleet, command-budget gate, anchors check.
13. [`13-human-decisions.md`](13-human-decisions.md) — U1–U11: breaking/default/security calls only a human makes.
14. [`14-adopter-tesote-com.md`](14-adopter-tesote-com.md) · 15. [`15-adopter-sales.md`](15-adopter-sales.md) · 16. [`16-adopter-gringotts.md`](16-adopter-gringotts.md) · 17. [`17-adopter-hiscore.md`](17-adopter-hiscore.md) · 18. [`18-adopter-legald.md`](18-adopter-legald.md) — per-repo follow-ups, each edited from its own repo.
19. [`19-infra-tesote.md`](19-infra-tesote.md) · 20. [`20-infra-developerz.md`](20-infra-developerz.md) — probes, scrape + alerts.

## Waves (≤4 agents per wave, disjoint file sets; PRs land one at a time)
| Wave | Slices / rows | Parallel split (file sets) |
|---|---|---|
| 0 — today | 01 C1; 14 S1 (other repo); 19 X1, 20 X1 (other repos) | 1 agent here + the other repos independently |
| 1 — correctness + guards | 02 R1+R2+R6; 03 G1–G4, G10; 01 C3–C8; 12 T3+T6 | A: `lib/wurk/fetcher/`, `lua.rb`, poison pill · B: `boot_checks.rb`, `cli.rb`, `rails_boot.rb` · C: `docs/` · D: `bench/`, `.github/`, `bin/check` |
| 2 — measure | 06 P1 + L0; 08 M0; 07 benches; 12 T1 ledger | A: `bench/vs_sidekiq*`, `bin/profile` · B: `bench/require_profile.rb` · C: `bench/rss_soak.rb`, `bench/soak/` · D: the 7 benches in 07 |
| 3 — drop-in + errors | 04 D1–D8; 05 E1–E8; 03 G5–G15; 02 R3–R5 | A: `wurk.gemspec`, `ecosystem/`, generators · B: `lib/wurk/web/` routes, proctitle · C: `testing.rb`, `sentry.rb`, `rails_reloader.rb`, `test/parity/` · D: `preflight/`, `swarm.rb` reclaim |
| 4 — cut cost (only rows the wave-2 numbers justify) | 06 L1+L2+L4 (one PR), P2–P6; 08 M1–M6; 07 A1–A6 | A: `lib/wurk.rb`, `compat.rb`, `cli.rb` pre-fork · B: `app/controllers/wurk/`, `batch_set.rb`, `flow_set.rb`, `job_set.rb` · C: `limiter/`, `lua/limiter_*`, `web/enterprise.rb` · D: `swarm.rb` memory, `client/buffered.rb`, caches |
| 5 — long tail | 07 A7–A19; 09; 11; 04 D9–D13; 10 | A: `cron.rb`, `metrics/` · B: `frontend/`, dashboard controllers · C: `health`/metrics export, `examples/`, `docs/deployment.md` · D: `test/ecosystem/`, `lib/wurk/api/`, `clients/python/` |
| 6 — proof + release + adopters | 12 T1 24h soak, T2; release; 15–18, 19 X2–X4 | soak is one agent; adopter repos one each |

Releases: after wave 1 (patch: reclaim fix + guards), after wave 3 (minor), after wave 4/5 (minor with published numbers). Adopter slices follow the release that carries what they remove.

## Done when
- `main` green; `bin/check full` green; coverage ≥90/90; `bin/rake test:parity` + `test:ecosystem` green.
- 02: poison race test fails on `f6f509e`, passes after; ≤1 keyspace SCAN pass per rolling restart.
- 03: every G-row has a test that fails without its guard; `wurk boot-check` runs in Wurk CI against `test/dummy` and in ≥3 adopter CIs.
- 04: treasury's plugin set + pinned shim resolves in a scratch app and boot-checks clean; doc 14 has pin + status for all 7 gems.
- 06–08: `docs/benchmarks.md` carries the CPU frame table, require profile (client vs server tier), per-child Rss/Pss + slope, Redis bytes/job per feature, feature/dashboard command costs — before and after. Commands per job did not rise. No "faster" claim unless those numbers support it.
- 07: page 999 costs page 0's round-trips; no Lua reads `0 -1` of a public queue; concurrent limiter ≤2 round-trips/job.
- 12: 24h soak — 0 lost jids, every duplicate attributed to a documented window, flat PSS + key-count slopes; mixed-fleet verdict written into the migration guide.
- Adopters: tesote.com dedup live; no `ps | grep` worker probes; each removed workaround names the Wurk version that retired it.
- 13: every U-row has a dated decision in `status.yml`.

## Risks / open questions
- **Lazy loading reintroduces the load-order crash class** adopters already hit. 03 G10 before 06 L1; L1+L2+L4 are one compile unit; verify per-child PSS does not rise (08 M0).
- **Reaper cadence (07 A4)** trades scan cost against lost-host reclaim latency; keep the documented 90–140 s bound or don't ship it.
- **Hot-path changes** (06 P2/P3/P6, 02) → `bin/rake bench` and `bin/rake bench:vs_sidekiq` on every PR; the earlier micro-optimisations all landed inside noise, hence P1 first.
- **Windowed fast-delete (07 A3)** must stay correct under concurrent pops; if it can't be proven, cap list size per call and document.
- **Upstream unknowns** to settle by oracle, not opinion: does stock Sidekiq report job errors to `Rails.error` per attempt (05 E1); unique under `Testing` (E5); proctitle format (04 D6); Pro `delete_by_class` chunking (A3); Ent limiter register-on-construct (A5).
- **Breaking defaults** (embedded opt-in, `authoritative!`, `WURK_COUNT`, key prefix, `sidekiq` exe) wait on [`13`](13-human-decisions.md).
- Inferred, not observed: CSP + sub-path breakage (09 W1/W2), PID-reuse stranding (02 R4), `api_only` auth, per-row Redis memory estimates (08 M8).
- Not covered by any sweep: production pods/Redis, hiscore Bugsnag + legald GlitchTip events, batches/encryption/iterable internals in depth, Rails 8.1 continuations — the soak (12 T1) is the backstop.
- Carry-over: real Pro/Ent Redis dump from the customer (U10) still outstanding.
