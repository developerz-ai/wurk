# 02 — Fetch loop, pause spin, reaper liveness

> Part of [`overview.md`](overview.md). Depends on: none.

## Files to change

- `lib/wurk/fetcher/reliable.rb:58-61, 69-80, 105-110, 150-152` — pause spin, private-list naming
- `lib/wurk/fetcher/reaper.rb:227-240, 284-290` — owner liveness across PID namespaces
- `lib/wurk/middleware/interrupt_handler.rb:37-40` — re-push end
- `docs/reliability.md:169-173` — update liveness docs

## Steps

1. **F1 (outage-class) — all-queues-paused hot-spin.** `retrieve_work` returns nil with no sleep when `queues_cmd` is empty; `Processor#run` (`processor.rb:140`) loops instantly, each pass paying `SMEMBERS paused` on the main pool → N threads saturate Redis + starve the pool. Fix: `if queues.empty? then sleep(poll_interval); return nil; end` — mirrors Sidekiq's BasicFetch guard (upstream #4825). Also add a short sleep on the `@done`-window nil between `Manager#quiet`'s fetcher terminate (`manager.rb:57`) and processor terminate (`:59`).
2. **F2 (job loss / dup execution) — reaper liveness wrong across PID namespaces.** Private list `queue:<q>|<host>|<pid>|<idx>` has no incarnation nonce; `owner_alive?` (`reaper.rb:227-240`) trusts `Process.kill(0, pid)` whenever `host == hostname`.
   - (a) Container restart with same hostname + fresh PID namespace → dead owner's pid "alive" → job stranded forever.
   - (b) Shared hostname, separate PID namespaces (hostNetwork) → live owner's pid "dead" → drain while executing → duplicate run.
   - Fix: extend key to `|<host>|<pid>|<nonce>|<idx>` using `Component::PROCESS_NONCE` (`component.rb:52` already has it for identity); gate the `kill(0)` fast path on `nonce == PROCESS_NONCE`, else fall through to heartbeat-membership check (namespace-safe).
   - **Wire-compat/migration**: reaper must keep recognizing and reclaiming old-format 4-part keys (parse both shapes) so in-flight jobs from a pre-upgrade process aren't stranded. New processes write only the new shape. Document in `docs/reliability.md` + `docs/idea/` (deliberate divergence — Sidekiq super_fetch has the same weakness).
3. **F7 — interrupt re-push at wrong end.** `interrupt_handler.rb:37-40` uses `LPUSH` but the fetcher pops the RIGHT end (`reliable.rb:156,169`); an interrupted IterableJob goes to the back of a deep queue and its `it-<jid>` cursor can expire → full re-processing. Fix: `RPUSH`, matching `UnitOfWork#requeue` (`reliable.rb:50`) and `Lua::RELIABLE_REQUEUE`'s comment (`lua.rb:101-103`). Fix the now-wrong comment too.

## Tests

- Unit: all queues paused → `retrieve_work` sleeps (assert no busy loop: Redis command count over 1 s bounded).
- Integration: old-format private-list key seeded in Redis → reaper reclaims it (migration window).
- Unit: reaper with matching host + dead nonce → falls to heartbeat check; stranded-job scenario reclaims; live-owner scenario does not drain. Simulate namespaces by stubbing nonce/hostname, real Redis for keys (never mock Redis in integration).
- Unit: interrupted job lands at fetch-next position (RPUSH) — assert next `retrieve_work` returns it ahead of older backlog.
- Commands: `bin/rake test`, `bin/rake test:parity`; `bin/rake bench` (fetch+execute unchanged — the sleep is idle-path only).

## Done when

- Paused-everything worker is Redis-quiet (≈1 poll per interval per thread).
- Both F2 scenarios covered by tests; old-key reclaim proven.
- IterableJob TSTP resume is next-fetched; parity suite green.
