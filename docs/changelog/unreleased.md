# Unreleased

### Added

- **`memory_limit_metric`** (`WURK_MAXMEM_METRIC`): recycle swarm children on `rss` (default), `pss` or `uss`. An unknown value raises at boot; a limit on a host without a readable `/proc` logs one WARN.
- **`Wurk::Client.reliable_push_buffer_bytes`** (opt-in): caps the outage buffer by payload bytes as well as by count. Past it the overflow mode applies; a payload larger than the cap on its own is dropped (or raised under `:raise`).
- `docs/deployment.md` "Memory": copy-on-write and the pre-fork warmup, allocator guidance (jemalloc, `MALLOC_ARENA_MAX`) and a table of Wurk-only keys with their TTLs.

### Changed

- **A concurrent-limited job costs 2 Redis round trips** (was 6), 3 when the limiter is built inside `perform` (was 7): the counters are booked inside the acquire and release scripts.
- **The periodic (cron) tick reads every loop in 2 round trips** instead of 1 + 2 per loop, and boot registration takes 2–3 instead of up to ~26,000 with many classes.
- **Fast deletes** (`Queue#delete_job`, `#delete_by_class`) walk the queue 1,000 entries per Lua call, holding Redis about 1 ms at a time instead of ~300 ms at 100k jobs. An entry another client removes ahead of the walk can be missed by that call; a second call finds it.
- **Dashboard metrics**: the 30-day top-jobs view allocates 60% less, the queue-history series reads only the requested queues (1.44M → 2,880 fields), queue gauges no longer store zero values, and a metrics flush sends one EXPIRE per shared key, as Sidekiq 8.1 does.
- **The job path allocates 26 fewer objects per job** (105 → 79 in `Processor#process_one`). The default log formatter builds each line in one buffer and caches `pid=`; built-in server middleware (interrupt handler, expiry, timeout, status, batch, limiter, statsd, metrics history) reuse one instance per chain entry, while host middleware still gets a fresh instance per job; the fetcher sends prebuilt commands. Log bytes, Redis keys, job JSON and the 3 commands per job are unchanged.
- **The swarm warms the heap before its first fork on every path**, the Rails auto-boot swarm and Ruby 3.2 included (full GC and compaction where `Process.warmup` is missing), and loads what children would otherwise load each (`fiddle`, cron time zones). Shared memory at boot measured 0.57 → 0.72 against no warmup.
- The heartbeat drains signals with one counted `RPOP` instead of ten; a CLI boot reads Redis `INFO` once instead of twice.
- **Outside a server process** (test runs, `rails runner`, web processes), a skipped `configure_server` block logs at DEBUG instead of WARN, as Sidekiq skips it silently. The block still runs if the process later enters server mode.

### Fixed

- **A memory limit below a freshly booted child's size no longer fork-loops the swarm.** A child already over the limit within its first 60s is reported once at ERROR and kept; a slot recycles at most once for that cause.
- **Per-process caches are bounded**: the queue-without-consumers warning map, the error coalescer (1,024 keys) and the Sentry middleware's thread-locals.
- A dead-set kill builds its synthetic backtrace only when death handlers will see it.
