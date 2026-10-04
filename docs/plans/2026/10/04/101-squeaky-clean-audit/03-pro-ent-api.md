# 03 — Pro/Ent + public API bugs

> Part of [`overview.md`](overview.md). Depends on: [`01`](01-repo-hygiene.md) (spec files restored — they are the oracle). Source: Pro/Ent audit 2026-10-04; items marked *repro* were reproduced against real Redis. Spec refs = `docs/target/sidekiq-{free,pro,ent}.md` §.

## Findings

### P1 — drop-in correctness

| ID | Where | Defect | Fix | Test |
|---|---|---|---|---|
| E1 | `lib/wurk/job_set.rb:75-92` `JobSet#each` | Fixed-offset paging skips entries when deleting during iteration (120 → 50 left, *repro*). | Port upstream offset compensation (re-read size, shift by deleted). | 120 entries `each(&:delete)` → size 0 (RetrySet, ScheduledSet, DeadSet). |
| E2 | `lib/wurk/queue.rb:80-90` `Queue#each` | Same skip. | `page*50 - (initial_size - size)` like upstream. | Same, on a queue. |
| E3 | `lib/wurk/batch/callbacks.rb:32-39` `propagate_to_parent` | Parent `:success`/`:complete` fires when child jobs drain, *before* child's own callback job runs → pro §2.9 step workflow breaks (*repro*). | Keep child in parent `-pkids` until its callback jobs finish (count callback jids as parent-live). | §2.9 workflow end-to-end. |
| E4 | `lib/wurk/lua.rb:280-284` (`BATCH_INVALIDATE` deletes `-jids`) + `batch/server_middleware.rb:37-40` | Invalidated batch never fires callbacks; `pending` stuck; parent never fires; retry/scheduled jobs inflate totals. Spec §12: cancelled counts as success (*repro*). | Keep `-jids`; ack invalidated jobs normally. | invalidate → drain → `complete_at` set + callbacks enqueued. |
| E5 | `lib/wurk/middleware/interrupt_handler.rb:38-41` + `encryption.rb:275` | **Plaintext secret leak**: encryption middleware decrypts `job['args']` in place; interrupt handler re-pushes mutated hash → plaintext in `queue:`, retry, dead (ent §4.3). | Re-push original `jobstr` (aligns with parse-once / carry-raw rule) or decrypt into a copy. Audit every other re-push site (retry, dead, requeue-on-shutdown) for the same pattern. | Interrupted `encrypt: true` IterableJob → re-pushed payload still has envelope. |
| E6 | `lib/wurk/cron.rb:649-665` `Poller#enqueue!` | Periodic push ignores worker `sidekiq_options` (queue, retry, unique_for, encrypt, expires_in). Ent §2.2: tick calls `perform_async`. | Resolve class; merge `get_sidekiq_options` under loop overrides. | worker `queue: 'low'` → lands in `queue:low`. |
| E7 | `lib/wurk/job_set.rb:129` `kill_all` | Defaults `notify_failure: true` (spec §19.5 / Sidekiq 8: false); trims per entry. Dashboard Kill All (`api_controller.rb:115`) fires every death handler per job. | Default false; kill `trim: false`, trim once. Fix `test/unit/job_set_test.rb:360` (asserts wrong default). | default false; one trim. |
| E8 | `lib/wurk/metrics/history.rb:48,168` | Minute keys `j\|YYYYMMDD\|H:M`; spec free §20 + Sidekiq 8.1 use `%y%m%d`. #317 (6aaeac8) checked 7.3; Wurk claims `Sidekiq::VERSION` 8.1.5 → swap orphans history. | Revert to `%y%m%d`. Note in CHANGELOG (Wurk-written 4-digit keys expire naturally). | `minute_key(Time.utc(2026,5,21,14,37)) == 'j\|260521\|14:37'`. |
| E9 | `lib/wurk/metrics/query.rb:26` | `Sidekiq::Metrics::Query` is a module; `.new(now:)` NoMethodError; `Result`/`JobResult`/`MarkResult` missing. | Spec-shaped class; keep module fns for dashboard. | parity: `Query.new.top_jobs.job_results[k].totals['p']`. |
| E10 | `lib/wurk/compat.rb:154-208` | Missing `Sidekiq::JobSet`, `Sidekiq::SortedSet` aliases → sidekiq-unique-jobs `class Sidekiq::JobSet; prepend` defines a new class → locks never released. | Add aliases. | Alias test: every spec class constant resolves to the Wurk class (generate list from spec). |
| E11 | `lib/wurk/testing.rb:92-107` | fake/inline skip JSON round-trip → symbol keys in tests, strings in prod. | `load_json(dump_json(job))` in `fake_push`/`inline_push`. | symbol-keyed hash → string keys. |
| E12 | missing `lib/sidekiq/*` shims | `sidekiq/middleware/current_attributes`, `sidekiq/middleware/i18n`, `sidekiq/pro/web`, `sidekiq-pro`, `sidekiq-ent`, `sidekiq-ent/web`, `sidekiq-ent/periodic/testing` → LoadError once sidekiq gem gone (masked locally by global sidekiq-8.1.6). | One-line pass-through shims. | Require each spec-listed path in a subprocess with sidekiq gem off load path (`ruby -I lib -e`, `GEM_PATH` stripped). |
| E13 | `lib/wurk/batch/callbacks.rb:118-136,186-191` | `b-<bid>-success`/`-complete` used as "fired" markers; Pro (§2.8) = "callbacks pending". Pro batches lack Wurk's `callbacks` field → in-flight Pro batches at swap skip/mis-fire callbacks. *plausible* | Move Wurk markers to non-Pro names; read Pro's callback storage. Validate with real Pro dump ([`09`](09-production-readiness.md) P1). | Parity fixture: Pro-shaped in-flight batch completes + fires. |

### P2 — robustness

| ID | Where | Defect | Fix | Test |
|---|---|---|---|---|
| E14 | `lib/wurk/lua/limiter_bucket_acquire.lua:23` + `limiter/bucket.rb:85` | `lmtr-b:<name>:<epoch>` keys get limiter TTL (90d) not ~interval → millions of keys. | EXPIRE ≈ `interval*2`. | `TTL <= 2` after `:second` acquire. |
| E15 | `lib/wurk/batch/server_middleware.rb:53-61` | Redis error in `maybe_fire` (inside rescue around `yield`) → successful job retried + double-run; callbacks never fire. | Move ack/maybe_fire outside the job rescue. | stub `maybe_fire` raise → no retry, 0 failures. |
| E16 | `lib/wurk/batch.rb:203-214` `remove_jobs` | Non-atomic; never calls `maybe_fire` → stranded batch (*repro*). | Single Lua + `maybe_fire`. | ack one, remove other → `:complete` enqueued. |
| E17 | `lib/wurk/batch/callbacks.rb:325-330` `pkids_drained?` | Two round-trips → siblings both see 0 → parent fires twice (comment at :28-31 wrong). *plausible* | Lua 1→0 transition gate. | concurrent stress: exactly one parent callback. |
| E18 | `lib/wurk/batch/status.rb:121-128` `Status#delete` | Doesn't detach from parent `-kids`/`-pkids`; non-atomic UNLINKs → parent blocked forever. | Remove from parent sets + parent `maybe_fire`, one MULTI. | delete child of drained parent → parent fires. |
| E19 | `lib/wurk/batch.rb:393` | `tags:<tag>` sets no TTL, never cleaned. | EXPIRE on add; SREM in `Status#delete`. | `TTL tags:<t> > 0`. |
| E20 | `lib/wurk/cron.rb:289-291,379-384` | Registered `paused: true` can never unpause (reads options JSON, Web writes hash field). | Paused = hash field only. | register paused → `HSET paused 0` → not paused. |
| E21 | `lib/wurk/cron.rb:571-609` `due_slot` | Backfills one missed run after outage; ent §2.6 says no backfill. | Stale slot > threshold → advance w/o enqueue. | slot 1h old → tick → nothing enqueued. |
| E22 | `lib/wurk/profiler.rb:51-58,104` | Field semantics differ (token, `type`, ms int vs float seconds). | Match upstream. | `ProfileRecord` field round-trip. |

### P3 — cleanup

- E23 `lib/wurk/lua/throttle_slot.lua`: builds key in Lua (undeclared key) — breaks Dragonfly/Cluster. Pass full key via `KEYS` (precedent #91). Also `lib/wurk/lua/flow_*.lua`, `limiter_list_sweep.lua` (production audit) — add a test that greps every `.lua` for `redis.call(` with a non-`KEYS[` key arg.
- E24: `💣` alias for `clear` on `SortedSet`/`Queue`; `Sidekiq.loader` (spec §30); `Queue#clear` (`queue.rb:105`), `DeadSet#trim` (`dead_set.rb:37`), `Process#signal` use pipeline not MULTI; `SortedSet#scan` double-wraps `*`; `cron.rb:297` flattens `args: {hash}`; flow node `at:` enqueued immediately (`flow/creation.rb:127`, `flow_create.lua:381`); batch callback round-trips (`record_event`, 12 EXPIREs in `apply_linger`, `Status#data`) → pipeline.

### Found by top-down / bottom-up passes (same slice)

| ID | Sev | Where | Defect | Fix | Test |
|---|---|---|---|---|---|
| E25 | P1 | `lib/wurk/batch.rb:261-275`, `client.rb:291-301` | Without `autoflush`, each push in `batch.jobs {}` hits `BATCH_PUSH` immediately; no pending sentinel while block open → A acks before B pushed → callbacks fire early, never again. Raise mid-block → partial batch (Pro atomic). | +1 pending sentinel released at block exit (or buffer by default). | push A, run A, push B → no callback until B acks. |
| E26 | P1 | `lib/wurk/batch/server_middleware.rb:76-77` | Ack returns `-1` (re-run after SIGKILL between ack Lua and callback enqueue) → return w/o `maybe_fire` → callbacks stranded. | On -1 call `maybe_fire` with current counts (dedup markers absorb repeats). | kill between ack + fire → reaper re-run fires callbacks once. |
| E27 | P1 | `lib/wurk/batch/callbacks.rb:117-137,266-276` | Callback enqueue failure only `logger.warn`, then `dedup_set` anyway → callback lost forever. | Skip `dedup_set` on failure; `handle_exception`. | `Client.push` raises once → callback fires on next attempt. |
| E28 | P1 | `lib/wurk/cron.rb:559-565` `tick` | Single rescue around `LoopSet#each`; one always-raising loop starves all later loops forever (stable SMEMBERS order). | Rescue per loop. | raising loop before healthy → healthy fires. |
| E29 | P2 | `lib/wurk/batch/death_handler.rb:117-136` via `job_retry.rb:274-280` | `BATCH_ACK_COMPLETE` failure swallowed by `run_death_handlers` after morgue+ACK → batch never `:complete`/`:death`. | Retry/record; reconcile on next ack. | stub ack raise → batch completes on retry path. |
| E30 | P2 | `lib/wurk/lua.rb:329` (`BATCH_APPEND_CALLBACK`), `batch.rb:354` | cjson re-encodes whole callbacks array: 15+ digit ints → `1.23e+17`, `[]`→`{}`, `/` escaped; corrupts earlier entries too. | Append raw JSON as string (like `RELIABLE_SCHEDULE_PROMOTE`) or one hash field per callback. | reopen batch + 17-digit int + `[]` → round-trip exact. |
| E31 ★★ | P1 | `lib/wurk/api/fast.rb:61-70`, `lib/wurk/job_set.rb:37,140-152` | `scan` without block / via Enumerator (arity -1) yields raw `[json, score]` → `RetrySet.new.scan('Foo').each(&:retry)` NoMethodError. | Base method always yields `SortedEntry`; `find_job` uses `entry.jid`. | `scan('x').map(&:jid)` works. |

Overlaps confirmed by multiple passes: E2 (Queue#each), E15 (server_middleware rescue), E16 (remove_jobs).

## Steps (hive: ≤4 agents per wave, disjoint files; batch cluster = 1 agent, cron cluster = 1 agent)
1. E5 first (secret leak).
2. E10 + E12 (cheap, unblock ecosystem gems + boot).
3. Batch cluster E3/E4/E13/E15–E19/E25–E27/E29/E30 as one PR series (shared files; one agent).
4. Cron cluster E6/E20/E21/E28 (one agent).
5. API iteration E1/E2/E7/E31/E24-atomics.
6. Metrics E8/E9, profiler E22.
7. E14, E23 Lua key audit.

## Tests
- Every row has its test. Batch + cron tests go in `test/integration/` (real Redis) **and** an independent oracle in `test/parity/` per [`08`](08-test-hygiene.md).
- `bin/rake test`, `bin/rake test:parity`, `bin/rake test:ecosystem` (unique-jobs relies on E10).

## Done when
- E1–E22 + E25–E31 fixed with tests; E23–E24 fixed.
- Any intentional divergence recorded in `docs/idea/parity-divergences.md`.
