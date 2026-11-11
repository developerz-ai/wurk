# Unreleased

### Added

- **`GET <retries|scheduled|dead>/:key`** in the dashboard API: one entry with its backtrace, which the job detail now fetches when opened.
- `docs/dashboard.md` "What the dashboard costs Redis".
- **`memory_limit_metric`** (`WURK_MAXMEM_METRIC`): recycle swarm children on `rss` (default), `pss` or `uss`. An unknown value raises at boot; a limit on a host without a readable `/proc` logs one WARN.
- **`Wurk::Client.reliable_push_buffer_bytes`** (opt-in): caps the outage buffer by payload bytes as well as by count. Past it the overflow mode applies; a payload larger than the cap on its own is dropped (or raised under `:raise`).
- `docs/deployment.md` "Memory": copy-on-write and the pre-fork warmup, allocator guidance (jemalloc, `MALLOC_ARENA_MAX`) and a table of Wurk-only keys with their TTLs.

### Changed

- **The dashboard costs a fixed number of Redis round trips.** The landing payload, each live-update tick and the queue list take 2 (were 9 and 6), and open streams in one process share one read per second. Queue detail and the retry, scheduled and dead pages take 1 at any depth; batches and flows take 2 at any depth (page 999 of batches was 25,276). The Limits tab checks limiter metadata at most once a minute per process.
- **Dashboard list payloads are smaller.** Batch rows report `failed_count` and `dead_count` instead of every failed and dead jid (the batch page still lists them), and job rows no longer carry `error_backtrace`. The HTTP API (`/v1`) rows are unchanged.
- **"Retry All"** removes and pushes a page of 50 jobs in one round trip each (0.06 round trips per job, was 2.02). When a gem hooks the per-entry methods (sidekiq-unique-jobs), it keeps the per-entry path so the gem still runs.
- **A concurrent-limited job costs 2 Redis round trips** (was 6), 3 when the limiter is built inside `perform` (was 7): the counters are booked inside the acquire and release scripts.
- **The periodic (cron) tick reads every loop in 2 round trips** instead of 1 + 2 per loop, and boot registration takes 2–3 instead of up to ~26,000 with many classes.
- **Fast deletes** (`Queue#delete_job`, `#delete_by_class`) walk the queue 1,000 entries per Lua call and remove at most 100 matches per call. Each call holds Redis well under 2 ms when nothing matches, up to ~10 ms when it removes entries halfway into a 1M-entry queue; the single script this replaced held Redis for the whole queue (~300 ms at 100k jobs). An entry another client removes ahead of the walk can be missed by that call; a second call finds it.
- **Dashboard metrics**: the 30-day top-jobs view allocates 60% less, the queue-history series reads only the requested queues (1.44M → 2,880 fields), queue gauges no longer store zero values, and a metrics flush sends one EXPIRE per shared key, as Sidekiq 8.1 does.
- **The job path allocates 26 fewer objects per job** (105 → 79 in `Processor#process_one`). The default log formatter builds each line in one buffer and caches `pid=`; built-in server middleware (interrupt handler, expiry, timeout, status, batch, limiter, statsd, metrics history) reuse one instance per chain entry, while host middleware still gets a fresh instance per job; the fetcher sends prebuilt commands. Log bytes, Redis keys, job JSON and the 3 commands per job are unchanged.
- **The swarm warms the heap before its first fork on every path**, the Rails auto-boot swarm and Ruby 3.2 included (full GC and compaction where `Process.warmup` is missing), and loads what children would otherwise load each (`fiddle`, cron time zones). Shared memory at boot measured 0.57 → 0.72 against no warmup.
- **`require "wurk"` loads 41% fewer files** (163 → 95; 186 → 110 ms, 17.5 → 12.5 MB RSS): the server, dashboard, flow, iterable-job, deploy and encryption code load on first use. A server boot takes 233 → 176 ms and the swarm still loads everything before it forks (`Wurk.eager_load!`), so children share it. `require "sidekiq/web"` and the other `sidekiq/*` sub-paths load only what they name. Every `Sidekiq::*` alias resolves to the same constant as before.
- **The dashboard's first load is 777 KB → 352 KB raw, ~104 KB served brotli** (before: no compression). Locales other than English load on demand; the 47 icons in use are inline SVGs instead of the Font Awesome fonts and stylesheet; the logo is resized and the unused Open Graph image and tags are gone. `rake frontend:build` writes `.br`/`.gz` next to each asset and the engine serves them by `Accept-Encoding`, with `Vary: Accept-Encoding`.
- `zlib` loads on the first compressed backtrace or profile, not at boot. A new integration test pins an idle worker's threads and Redis connections.
- The heartbeat drains signals with one counted `RPOP` instead of ten; a CLI boot reads Redis `INFO` once instead of twice.
- **Outside a server process** (test runs, `rails runner`, web processes), a skipped `configure_server` block logs at DEBUG instead of WARN, as Sidekiq skips it silently. The block still runs if the process later enters server mode.

### Fixed

- **A memory limit below a freshly booted child's size no longer fork-loops the swarm.** A child already over the limit within its first 60s is reported once at ERROR and kept; a slot recycles at most once for that cause.
- **Per-process caches are bounded**: the queue-without-consumers warning map, the error coalescer (1,024 keys) and the Sentry middleware's thread-locals.
- A dead-set kill builds its synthetic backtrace only when death handlers will see it.
