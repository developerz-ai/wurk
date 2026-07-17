# 07 — Parity / spec alignment

> Part of [`overview.md`](overview.md). Depends on: none (04 step 6 lands its divergence record here).

Audit verdict: implementation is unusually faithful — retry math, scheduler poll math, atomic push, heartbeat schema, config defaults, unique jobs, limiter keys, batch callback ordering, ~30 spot-checked `Sidekiq::*` aliases all match. Five real divergences + one spec-internal conflict remain.

## Files to change

- `docs/target/sidekiq-free.md:53` vs `docs/target/sidekiq-ent.md:566,818` — leader key spec conflict (`dear-leader` vs `leader`, identity `host:pid:nonce` vs `pid@host:nonce`).
- `docs/idea/` — divergence records (create if pattern requires).
- `lib/wurk/dead_set.rb:41` — trim off-by-one (fixed in 04 step 7; verify here).
- `lib/wurk/compat.rb:104` — `BasicFetch = Wurk::Fetcher::Reliable`.
- `lib/wurk/limiter/server_middleware.rb:13-17,44` — dead-set-at-cap divergence comment references #16.
- `lib/wurk/fetcher/reaper.rb:272` — LMOVE RIGHT/RIGHT vs spec RPOPLPUSH.

## Steps

1. **Reconcile the leader spec conflict.** Code follows free spec (`leader.rb:28` `dear-leader`, `leader.rb:190-192` `host:pid:nonce`) and `Sidekiq::Process#leader?`/`ProcessSet#leader` agree (`sidekiq-free.md:1103,1120`). Amend `sidekiq-ent.md` §6.4 + §12 to match the free spec (single source of truth), noting an Ent install migrating with a live `leader` key simply re-elects — one-time, harmless. Do NOT change the code key.
2. **Record intentional divergences in `docs/idea/`** (one short doc each or one combined `parity-divergences.md`):
   - Reliable fetch as default + `BasicFetch` aliased to it (`compat.rb:104`): in-flight jobs live in `queue:<q>|host|pid|N` private lists, not removed-by-BRPOP; external tooling reading raw queue LLEN sees different state. Deliberate (pillar: reliability by default; no BRPOP mode exists or will).
   - Limiter reschedule-cap → dead set instead of re-raise (Ent §1.4; `limiter/server_middleware.rb:44`, decision #16): poison-brake semantics; jobs hit morgue at exactly `reschedule` attempts instead of flowing through retry chain.
   - Orphan reclaim `LMOVE RIGHT RIGHT` (recover-first ordering) vs spec RPOPLPUSH head-insert (`reaper.rb:272`, Pro §3.2).
   - `bulk_requeue` semantics change from 02 (atomic private→public move vs Pro's retain-in-private).
3. **Verify small parity fixes landed** (owned by 04): dead-set trim retains `dead_max_jobs - 1` per spec `sidekiq-free.md:1579`; `parse_or_kill` trims.
4. **Ent §8 rolling-restart check.** Spec permits a Wurk-native equivalent documented in `docs/idea/` — swarm USR1 restart exists (`swarm.rb:86-99`, reworked in 03); write the §8 note (no einhorn compat; USR1-to-supervisor is the mechanism).
5. **Spec-doc guard.** The three `docs/target/*.md` files were found deleted (uncommitted) in the worktree and restored during this audit. Add a CI check (or test) asserting they exist and are non-empty — they are the authoritative oracle per CLAUDE.md.

## Tests

- `bin/rake test:parity` — full parity suite green after 01–04 land.
- Doc presence test for `docs/target/*.md`.
- No new runtime behavior in this slice beyond what 04 landed.

## Done when

- `sidekiq-free.md` and `sidekiq-ent.md` agree on leader key + identity format.
- Every known divergence has a `docs/idea/` record (spec preamble requirement satisfied).
- Parity suite green; spec files guarded against silent deletion.
