# 02 — Orphan reclaim correctness (reaper · poison pill · private lists)

> Part of [`overview.md`](overview.md). Depends on: none. Highest-value runtime defect. 2 PRs (R1+R2+R6 · R3+R4+R5).

## Files to change
| ID | Sev | Where | Defect → scenario | Fix |
|---|---|---|---|---|
| R1 | P1 | `lib/wurk/lua.rb:163-170` (`RELIABLE_RECLAIM`); `lib/wurk/fetcher/reaper.rb:327-368` (`drain` → `poison_off`); `lib/wurk/middleware/poison_pill.rb:185-194` | Poison check runs AFTER `RPUSH public`. A worker parked in `BLMOVE` takes the job inside that push → counter hits cap → ZADD `dead` + death handlers (batch death callback, unique release) fire while the job runs a 4th time; `LREM public -1` then walks the whole backlog, O(N), finds nothing. Guard fails exactly when the fleet is idle. Code comment at `reaper.rb:361` admits "the job is back on its queue whatever happens here". | Decide before pushing: `LINDEX private -1` → jid → `INCR`+`EXPIRE` in one pipeline/Lua → over cap: Lua move private→`dead` (same member + score format as `DeadSet#kill`), then death handlers; else `RELIABLE_RECLAIM`. Keep the `OomDrain` path (`reaper.rb:347`) and the lost-reply note at `reaper.rb:321-326`. Same keys, same scores. |
| R2 | P2 | `poison_pill.rb:185-191` `bump_counter` | `INCR` then `EXPIRE` separate → `super_fetch:recovered:<jid>` with no TTL on a blip. | Folded into R1's pipeline. |
| R3 | P2 | `lib/wurk/launcher.rb:244`; `reaper.rb:181,227` (`boot_reclaim!` → `sweep` → `SCAN MATCH queue:*\|* COUNT 1000`); `docs/reliability.md:227` | Every swarm child SCANs the whole keyspace at every boot / USR1 / memory recycle, lock-free: O(keyspace) × N children per deploy. Old audit R16, still open. | (a) Swarm parent reclaims a dead child's lists by exact key in `Swarm#on_child_exit` (`lib/wurk/swarm.rb:545`): it knows pid, `PROCESS_NONCE`, hostname, slot queues → `Reliable.private_queue_name` → `reliable_reclaim` via R1's path. (b) Boot SCAN goes behind the existing `super_fetch:reaper` lock; loser skips. Parent uses a short-lived connection, closed before the next fork (boot step 3). |
| R4 | P3 suspect | `reaper.rb:256-292` `local_pid_alive?` (`kill(0)`, EPERM = alive) | PID reuse by an unrelated process strands a dead sibling's list until that process exits. | R3(a) removes the dependency for swarm children. Optional: compare `/proc/<pid>/stat` starttime. |
| R5 | P3 | `lib/wurk/fetcher/reliable.rb:85`, `lib/wurk/leader.rb:289`, `lib/wurk/component.rb:72` | Hostname derived in 3 places; drift → private-list host ≠ reaper host → 30s+ heartbeat path. | `Component.hostname` everywhere. |
| R6 | P3 | `lib/wurk/middleware/poison_pill.rb:22-27` | Not a middleware (own header says so); producer = Reaper, consumer = ACK. | Move file to `lib/wurk/fetcher/poison_pill.rb` with R1; constant path unchanged (Pro surface, `lib/wurk/compat.rb`). |
| R7 | — | reaper `PrivateListKey` (`parse_full` / `parse_owner`) | #751 class: numeric host + `\|` in queue name drained a live owner. No property test. | See Tests. |

## Steps
1. R1: write the failing integration test first (parked consumer), then the Lua + Ruby change. Layer: Fetcher/Reaper only (`lib/CLAUDE.md`); `DeadSet` owns the dead-set write format — reuse, don't re-encode.
2. R3: `Swarm` owns child exit; it calls a Reaper class method, it does not learn key shapes itself.
3. `bin/repin-anchors` after each PR (ledger pins reaper + poison-pill ranges; `docs/idea/parity-divergences.md` "poison kill fires death handlers" entry stays true — re-read it).
4. Bench every PR: `bin/rake bench` (fetch path untouched, but `lua.rb` loads on boot).

## Tests
- New `test/integration/reaper_poison_race_test.rb`: real fork parked in `BLMOVE` on the queue; job with counter at cap−1 in a dead owner's private list; reclaim → job never delivered, exactly one `dead` entry, death handler once, private list empty.
- `test/unit/fetcher_reaper_test.rb:185-211`: keep; add no-TTL assertion (`TTL super_fetch:recovered:<jid>` > 0 after one bump).
- New `test/unit/private_list_key_property_test.rb`: seeded random queues (with `|`, `:`), numeric hosts, nonce/pid shapes, Pro 4-part shape → `parse_full` round-trips and agrees with `parse_owner`.
- New `test/integration/swarm_parent_reclaim_test.rb`: `kill -9` a child holding a job → job back on the public queue before the replacement's first heartbeat; `MONITOR`-free check: no `SCAN` issued by the replacement when the lock is held.
- `bin/rake test:parity`; `bin/check`.

## Done when
- Race test fails on `f6f509e`, passes after R1.
- A rolling restart of N children issues ≤1 keyspace SCAN pass (assert via `INFO commandstats` delta in the integration test).
- No `LREM` on a public queue remains in `reaper.rb`.
