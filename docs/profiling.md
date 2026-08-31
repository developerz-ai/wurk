# Job profiling

Wurk can capture a sampling profile of a single job's execution and store it in
Redis, where the dashboard's **Profiles** pane can hand it to
[profiler.firefox.com](https://profiler.firefox.com) as a flame graph. It's the
Sidekiq 8.0+ profiling feature, wire-compatible with Sidekiq's own Profiles
pane (same `profiles` ZSET, same `<token>-<jid>` HASH).

| Surface | What it is | Where |
|---------|------------|-------|
| `profile` job option | Opt a push into capture; the value is the profile's label | `sidekiq_options` / `set(...)` |
| `Wurk::Profiler` | Capture hook + Redis storage | `lib/wurk/profiler.rb` |
| `Wurk::ProfileSet` / `Wurk::ProfileRecord` | Read-only data API over stored profiles | `lib/wurk/profile_set.rb` |
| `GET <mount>/api/profiles` | JSON list backing the Profiles pane | `Wurk::ApiController#profiles` |
| `GET <mount>/profiles/:key` | Upload to the Firefox profiler, 302 to the view | `Wurk::ProfilesController#show` |
| `GET <mount>/profiles/:key/data` | The raw gzipped profile JSON | `Wurk::ProfilesController#data` |

Aliases: `Sidekiq::Profiler`, `Sidekiq::ProfileSet`, and `Sidekiq::ProfileRecord`
all point at the `Wurk::*` classes.

> **Vernier is required and is not a dependency of Wurk.** Capture is a plain
> `yield` unless `::Vernier` is defined in the worker process. Profiling is an
> opt-in dev/staging tool, so the gem stays optional.

---

## Enabling a profile

Add `vernier` to the process that runs jobs:

```ruby
# Gemfile
gem "vernier", require: true, group: :development
```

Then set the `profile` option on the push. The value is a free-form label —
it's stored as the profile's `type` and is what you see in the dashboard's
**Type** column, so name it after what you're investigating:

```ruby
# one push only — the usual way to profile
SlowReportJob.set(profile: "slow-report-2026-07").perform_async(account_id)
```

```ruby
# every push of this class — use sparingly, see the caveat below
class SlowReportJob
  include Sidekiq::Job
  sidekiq_options profile: "slow-report"

  def perform(account_id) = Report.generate(account_id)
end
```

`profile` is an ordinary job-hash key (spec `docs/target/sidekiq-free.md` §2.2),
so it survives normalization, `push_bulk`, and scheduled pushes unchanged.

**There is no dashboard button to start a profile, and no way to profile a job
that is already enqueued.** The Profiles pane is read-only: it lists what has
already been captured. The option has to be on the payload at push time.

---

## What gets captured

`Wurk::Profiler.call` sits inside the processor's dispatch onion, so the
capture window covers:

- the Rails reloader wrap,
- worker instantiation and the local retrier,
- the **entire server middleware chain**,
- `perform` itself.

It excludes fetching from Redis, `Wurk::JobLogger`, and the stats/work-state
bookkeeping that wrap it.

Vernier is a **sampling** profiler with native-stack and GVL awareness — it
samples on a timer rather than instrumenting every call, so the shape of your
hot path is accurate but very short frames may not appear. Overhead is small
but not zero, and the tail cost is the serialization + gzip + Redis write after
the job finishes (`elapsed` measures the job, not the storage).

Wurk exposes **no sampling controls** — no interval, allocation mode, or
`hooks:` knob. `Vernier.profile(out: <tempfile>)` is called with its defaults.
If you need different settings, call Vernier yourself inside `perform`.

Two behaviours worth internalising:

- **A failed job produces no profile.** The job's exception propagates straight
  out of the capture block (there is deliberately no blanket rescue there, so
  retries and `JobRetry::Skip` still work) — which means the storage step is
  never reached. Profiling only tells you about jobs that succeeded.
- **A storage failure never fails the job.** Everything after the job
  completes is wrapped: a Redis hiccup while persisting goes to
  `Wurk.configuration.handle_exception` with context `Wurk::Profiler` and the
  job still reports green.

---

## Storage, format, and footprint

The profile is Firefox-profiler ("gecko") JSON, gzipped, written to two keys:

| Key | Type | Contents |
|-----|------|----------|
| `profiles` | ZSET | member = `"<token>-<jid>"`, score = expiry epoch seconds |
| `<token>-<jid>` | HASH | `jid`, `type`, `token`, `started_at`, `elapsed`, `size`, `sid`, `data` |

- `token` is `SecureRandom.hex(8)`, so profiling the same `jid` twice (a retry)
  yields two distinct records rather than clobbering one.
- `type` is the label you passed as `profile`.
- `started_at` is epoch **seconds**; `elapsed` is the job's wall time in
  **milliseconds**.
- `size` is the **gzipped** byte count — the same number the dashboard shows.
- `sid` is the capturing process's identity (`Wurk.configuration[:identity]`).
  It's stored but not surfaced in the JSON API.
- `data` is the gzipped gecko JSON itself.

**Retention is 7 days** (`Wurk::Profiler::TTL`), enforced twice: an `EXPIRE` on
the HASH, and a ZSET score of `now + TTL` that `ProfileSet` purges with
`ZREMRANGEBYSCORE` on every read. There is no configuration knob for it.

Footprint: a gecko profile is genuinely large — hundreds of KB to several MB
gzipped for a long job. That lives in Redis memory for a week. Profile a
handful of pushes, not a queue.

---

## The data API

```ruby
set = Wurk::ProfileSet.new    # snapshots non-expired member keys, purging first
set.size                      # => Integer

set.each do |rec|
  rec.jid         # String
  rec.type        # String — the label you passed as `profile`
  rec.token       # String
  rec.size        # Integer, gzipped bytes
  rec.elapsed     # Integer, ms
  rec.started_at  # Time, or nil if the field is absent/blank
  rec.key         # "<token>-<jid>" — the id used by the web routes
  rec.data        # gzipped gecko JSON bytes, or nil if the HASH expired
end
```

`ProfileSet` includes `Enumerable`, so `map`/`select`/`sort_by` all work. Two
implementation details that matter operationally:

- **Membership is snapshotted at construction.** Build a new `ProfileSet` to
  see profiles captured since.
- **`each` uses `HMGET` on metadata fields only**, pipelined into a single
  round-trip. It never pulls the multi-MB `data` blob — that's fetched lazily,
  per record, by `#data` (or `Wurk::ProfileRecord.data_for(key)` when you have
  a key and don't want to materialise the record).

`#data` returns **gzipped bytes**, not JSON. Unzip with the profiler's own
helper:

```ruby
rec  = Wurk::ProfileSet.new.first
json = Wurk::Profiler.gunzip(rec.data)
File.write("profile.json", json)
```

`Wurk::Profiler.store(jid:, type:, gecko_json:, started_at:, elapsed_ms:,
token:, sid:, pool:)` is public and writes a record directly — useful for
seeding a demo or storing a profile you captured yourself. It returns the
storage key.

---

## Viewing a profile

Open the **Profiles** page in the dashboard. It polls `GET <mount>/api/profiles`
every 5 seconds and lists type, jid, start time, elapsed, and size, newest
first, with an **Open** link per row.

That link is a full navigation to `GET <mount>/profiles/:key`, which:

1. returns **403** if the dashboard is in read-only mode — uploading a profile
   to a public store is a side effect, and a read-only deploy (like the public
   demo) must not let a visitor exfiltrate one;
2. `POST`s the gzipped blob to `profile_store_url`
   (`https://api.profiler.firefox.com/compressed-store` by default) with
   `Content-Encoding: gzip`, using a 5s open / 15s read timeout;
3. **302**s you to `profile_view_url % <returned hash>`
   (`https://profiler.firefox.com/public/%s`).

Both URLs are configurable — point them at a self-hosted profiler if uploading
to Mozilla's public store is not acceptable:

```ruby
# config/initializers/wurk.rb
Wurk::Web.configure do |c|
  c.profile_store_url = "https://profiler.internal.example.com/compressed-store"
  c.profile_view_url  = "https://profiler.internal.example.com/public/%s"
end
```

The bracket form (`c[:profile_view_url] = …`, the Sidekiq spelling) sets the
same underlying option.

Failures are terse by design: unknown key → **404**, upload failure or a
non-2xx from the store → **502** (the underlying exception goes to
`handle_exception` with context `Wurk::ProfilesController#upload`).

### Without the upload

To keep the profile inside your network, grab the raw blob and load it into
`profiler.firefox.com` from a local file (or any gecko-format viewer):

```bash
curl -sS --compressed -b "$SESSION_COOKIE" \
  https://app.example.com/wurk/profiles/<token>-<jid>/data > profile.json
```

That endpoint streams the stored bytes with `Content-Encoding: gzip`, so
`--compressed` (or any browser) decompresses them for you. It's a `GET`, so
the CSRF same-origin rule doesn't apply — but it *is* behind whatever
authentication gates the mount.

---

## Gotchas

- **No vernier, no profile — and no warning.** The option is silently ignored
  when the gem isn't loaded in the worker process. Loading it in your web dyno
  does nothing; it has to be in the process that runs jobs.
- **`sidekiq_options profile:` on a hot class is a Redis-filling foot-gun.**
  Every successful push stores a multi-MB blob for 7 days. Prefer
  `set(profile: …)` on individual pushes.
- **Don't leave profiling on in production.** Sampling overhead per job plus a
  serialize-and-gzip after every one is real, and profiles are unredacted stack
  data.
- **The `data` route and the profile records contain code paths and method
  names** — treat the Profiles pane as sensitive and gate the mount (see
  [Authentication](authentication.md)).
- **`elapsed` is not your job's latency metric.** It's wall time inside the
  capture block, measured with a monotonic clock, and includes the server
  middleware chain. Use [Metrics](metrics-history.md) for real latency.
- **Profiles disappear after 7 days**, and the record may vanish between
  listing it and reading `#data` (`nil` / 404). Download anything you care
  about.
- **The Profiles tab lists everything captured cluster-wide**, not just the
  local process — `sid` records which process captured it but isn't shown.

---

## Profiling Wurk itself — `bin/profile`

Everything above profiles *your* jobs. To profile Wurk's own hot paths against
a real Redis (the repo's own tool, `stackprof`, dev group):

```bash
bin/profile                 # fetch+execute — the path the bench gate protects
bin/profile enqueue         # client push
bin/profile fetch --alloc   # allocation counts instead of CPU samples
bin/profile fetch --dump    # keep the raw dump for `stackprof tmp/profile.dump --method …`
```

| Env var | Default | Meaning |
|---|---|---|
| `PROFILE_LIMIT` | `25` | frames printed in the top-frames report |
| `PROFILE_ITERATIONS` | `50000`, or `2000` under `--alloc` | jobs pushed/executed per run — allocation mode is far slower, hence the lower default |
| `WURK_BENCH_DB` | `15` | Redis logical DB, which the run **FLUSHDBs**; never 0 (see [Benchmarks](benchmarks.md)) |

Both knobs trade run time for signal: raise `PROFILE_ITERATIONS` when a frame
you care about is buried in startup noise, raise `PROFILE_LIMIT` when the
interesting frame is below the cut.

---

## Related

- [Dashboard](dashboard.md) — mounting, tabs, and web config.
- [Authentication & authorization](authentication.md) — gating the mount and
  read-only mode (which blocks the profile upload).
- [Metrics history](metrics-history.md) — the aggregate view; profiling is the
  microscope you reach for after metrics point at a class.
