# 02 — Shutdown / requeue safety (double-execution fix)

> Part of [`overview.md`](overview.md). Depends on: none.

Two independent audits confirmed: every job still in-flight at `shutdown_timeout` runs **twice** — once from `bulk_requeue`'s RPUSH to the public queue, once from the boot reaper reclaiming the never-LREM'd private-list copy.

## Files to change

- `lib/wurk/fetcher/reliable.rb:84-95` — `bulk_requeue` is additive (RPUSH public only, no private LREM).
- `lib/wurk/manager.rb:100-109` — `hard_shutdown` calls `bulk_requeue(jobs)` then `kill` (no ack).
- `lib/wurk/processor.rb:181-185` — `Wurk::Shutdown` branch leaves job in private list (by design — keep).
- `lib/wurk/manager.rb:41,50,63,79-88` — `@workers` Set read/iterate without `@plock`.
- `lib/wurk/fetcher/reliable.rb:69` — dead `@done` guard; `fetcher.terminate` has no callers.
- `lib/wurk/swarm/child_boot.rb:22,70` + `lib/wurk/launcher.rb` — CONT resume is a dead contract.

## Steps

1. **Kill the double path.** Under reliable fetch the private list *is* the recovery mechanism. Make `Reliable#bulk_requeue` an atomic private→public move: for each UoW, pipelined `LREM private_list 1 job` + `RPUSH public_q job` (or simpler: make it a no-op and rely on the boot reaper — but that delays recovery until next boot; prefer the atomic move so jobs are visible immediately after a deploy). Either way, the job must exist in exactly one place afterwards. Note the spec cross-check: Sidekiq Pro super_fetch retains in-flight in the private list — a no-op `bulk_requeue` is the spec-faithful option (`docs/target/sidekiq-pro.md` §3); the LREM+RPUSH move is the operationally nicer one. Pick the move; record rationale in code + `docs/idea/` (see 07).
2. **hard_shutdown race trim.** `manager.rb:101` reads `processor.job` cross-thread; a processor can ack between the map and the requeue → same job moved twice. After step 1's LREM-based move this degrades gracefully (LREM misses, RPUSH must be conditional on LREM result — use a small Lua or check LREM return, skip RPUSH when 0). This closes the race completely.
3. **Manager locking.** Wrap `@workers` iteration/reads in `@plock` (`manager.rb:41,50,63`); `quiet`/`stop` snapshot under lock then act outside it. `@done` write+read both under the same lock (`manager.rb:82`).
4. **Quiet actually stops fetching.** On `quiet`, call a real `fetcher.terminate` (set `@done`, `reliable.rb:69` guard becomes live) so a processor mid-BLMOVE can't pull a fresh job post-quiet (`processor.rb:140` only checks between iterations).
5. **CONT resume.** Documented contract (`swarm.rb:26`): TSTP pause / CONT resume. Add `Launcher#resume` → `Manager` un-quiet is impossible (processors are terminated) — instead implement pause at the **fetcher** level: TSTP sets fetcher paused (processors idle-loop), CONT unpauses. Add a `CONT` entry to `CHILD_SIGNALS` (`child_boot.rb:22`) instead of resetting it to DEFAULT (`child_boot.rb:70`). Keep Sidekiq-compatible TSTP semantics per `docs/target/sidekiq-free.md` signals section — verify before implementing: if Sidekiq's TSTP is one-way (quiet, no resume), match Sidekiq and instead fix the *docs* (`swarm.rb:26` comment + CLAUDE.md signals table) to drop the resume claim.
6. **Processor replacement leak.** `Manager#processor_result` (`manager.rb:79-88`): if `Processor.new`/`start` raises, concurrency silently drops by 1 forever. Rescue, log, retry replacement on next tick (or re-raise to crash the child so the swarm respawns it — crash-visible beats silent degradation; pick crash).

## Tests

- Integration (real forks + Redis): enqueue a job that sleeps past `shutdown_timeout`, TERM the process, boot a new one, assert the job executes exactly **once more** (total 2 executions max is current buggy behavior; must be 1). Private list empty after `bulk_requeue`.
- Unit: `bulk_requeue` LREM-miss → no RPUSH; quiet → fetcher returns nil immediately; TSTP/CONT round-trip (if resume path chosen).
- Race test for `quiet` during processor churn (loop start/kill under `parallelize_me!`).
- Commands: `bin/rake test`, `bin/rake test:parity` (parity oracles cover shutdown semantics).

## Done when

- Timed-out-shutdown job runs once, not twice (integration proof).
- No `Set` concurrent-modification possible on `@workers`.
- Quiet halts fetch immediately; signals table in CLAUDE.md matches actual behavior.
