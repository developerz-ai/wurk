# Periodic (cron) jobs

Wurk has Enterprise-grade periodic jobs built in — no `sidekiq-cron`, no
`sidekiq-scheduler`, no `fugit`. You register loops at boot, the elected cluster
leader ticks once a minute, and exactly one process in the cluster enqueues.

| Surface | What it is | Where |
|---|---|---|
| `config.periodic { \|mgr\| … }` | Registration DSL, run at boot | `config/initializers/wurk.rb` |
| `Wurk::Cron::LoopSet` | Enumerable view of every registered loop | Ruby |
| `Wurk::Cron::ConfigTester` | Boot-time validator (cron syntax + class resolution) | Ruby / tests |
| `Wurk::Cron.fire!(lid)` | Fire one loop now, bypassing leader + schedule | Ruby / specs |
| Dashboard **Cron** tab | Pause, unpause, enqueue-now, run history | `<mount>/cron` |

The Sidekiq Enterprise names are aliases of the same objects:
`Sidekiq::Periodic` → `Wurk::Cron`, `Sidekiq::Periodic::LoopSet`,
`Sidekiq::Periodic::ConfigTester`, `Sidekiq::Periodic.fire!`, and
`Sidekiq::CronParser` → `Wurk::Cron::Parser`. There is deliberately **no
`Sidekiq::Cron`** constant — that namespace belongs to the third-party
`sidekiq-cron` gem, and squatting it breaks the gem when it runs alongside Wurk.

---

## Registering loops

```ruby
# config/initializers/wurk.rb
Wurk.configure_server do |config|
  config.periodic do |mgr|
    mgr.tz = "America/Chicago"                    # default for subsequent calls
    mgr.register("*/5 * * * *", "ReportJob")
    mgr.register("0 4 * * *", "NightlyJob", queue: "low", retry: 2, args: ["nightly"])
    mgr.register("0 * * * *", "TZJob", tz: "Asia/Tokyo")
  end
end
```

`configure_server` only yields in server processes, so registration writes to
Redis when a worker boots — not from your web dynos or a `rails console`.
Multiple `config.periodic` blocks accumulate onto one shared Manager.

### `mgr.register(cron, klass, **opts)`

| Param | Type | Notes |
|---|---|---|
| `cron` | `String` | 5-field crontab or an `@alias`. One minute is the finest resolution. |
| `klass` | `String` or constant | A constant is accepted and `to_s`'d, but a String avoids boot-order problems (the class needn't be loaded yet). |
| `queue:` | `String` | Defaults to `"default"`. |
| `retry:` | any | Written verbatim into the job payload. Defaults to `true`. |
| `args:` | `Array` | Static, evaluated **once at boot**, splatted into `perform_async` on every fire. |
| `tz:` | `String` / `ActiveSupport::TimeZone` / `TZInfo::Timezone` | Overrides `mgr.tz` for this call. Never enters the job payload. |
| `paused:` | `true` / `"1"` | Registers the loop in a paused state. |

Any other key you pass is stored in the loop's options hash and — because it
feeds the loop identity — changes the loop's `lid`. It is *not* copied into the
job payload; only `class`, `args`, `queue`, and `retry` are pushed.

`register` returns the `Wurk::Cron::Loop` and persists it to Redis immediately.
An invalid cron string or an empty/non-String class name raises `ArgumentError`
right there at boot.

There is also a convenience module method, `Wurk::Cron.register(name, cron,
worker_class, args = [], **opts)`, which stores `name` as a `label` option. The
label participates in the loop identity, so it is not a rename-safe handle —
prefer the `config.periodic` DSL.

---

## Cron syntax

Five fields, `minute hour day-of-month month day-of-week`, plus these aliases:

| Alias | Expands to |
|---|---|
| `@hourly` | `0 * * * *` |
| `@daily`, `@midnight` | `0 0 * * *` |
| `@weekly` | `0 0 * * 0` |
| `@monthly` | `0 0 1 * *` |
| `@yearly`, `@annually` | `0 0 1 1 *` |

Each field supports `*`, a value, a `a,b,c` list, an `a-b` range, and a
`base/step`. Ranges are validated (`5-1` and out-of-range values raise), steps
must be `>= 1`, and day-of-week `7` normalizes to `0` (Sunday).

Step bases follow Vixie cron: a bare value base means *from that value to the
field maximum*, so `5/15` in the minute field is `5,20,35,50` — not just `5`.

If **both** day-of-month and day-of-week are restricted they are OR'd, so
`0 0 13 * 5` means "the 13th, or any Friday". If only one is restricted, that
one must match.

Not supported — the parser rejects or ignores them, so don't port them from
another scheduler:

- No seconds field (6-field expressions raise; minimum frequency is one minute).
- No name aliases: use `0`–`7` and `1`–`12`, not `MON` or `JAN`.
- No `L`, `W`, `#`, `?`, or `@reboot`.

---

## Timezones

`tz` may be an IANA string (`"Europe/Berlin"`), an `ActiveSupport::TimeZone`, or
a `TZInfo::Timezone`. Nil means UTC.

The parser walks forward minute by minute evaluating wall-clock components in
the loop's zone, so DST is handled without special cases:

- **Spring forward:** the skipped local hour simply never matches, so a
  `0 2 * * *` loop does not fire on that date.
- **Fall back:** a *fixed-hour* schedule fires once — the repeated wall-clock
  minute is detected and the duplicate dropped. An *hourly* schedule (wildcard
  hour) keeps both repeated hours, because both are genuine runs.

IANA strings are resolved through `tzinfo` (a soft dependency, always present
under Rails via ActiveSupport) and memoized process-wide. A missing gem or an
unknown identifier logs one warning and evaluates the loop **as UTC** rather
than crashing the poller. Wurk never mutates `ENV['TZ']` — that is process-global
and would leak the schedule's zone into your `perform` code.

---

## The registry: loops, lids, and Redis

A loop's identity is `SHA1(schedule | klass | sorted options)`, truncated to 16
hex chars. Re-registering the same triple rewrites the same Redis keys, which is
what makes boot idempotent across every worker process and every deploy.

| Key | Type | Contents |
|---|---|---|
| `periodic` | SET | every `lid` |
| `loops:{lid}` | HASH | `schedule`, `klass`, `options` (JSON), `tz`, `paused`, plus the poller's `lf` (last fire) / `nf` (next fire) marks |
| `loop-history:{lid}` | LIST | newest-first `[fired_at, jid]` tuples, capped at 25 |

Read it back from anywhere that has Redis:

```ruby
loops = Wurk::Cron::LoopSet.new     # or Sidekiq::Periodic::LoopSet.new
loops.size
loops.each do |lp|
  lp.lid            #=> "0a4f…"
  lp.schedule       #=> "*/5 * * * *"
  lp.klass          #=> "ReportJob"
  lp.options        #=> { "queue" => "low", "args" => ["nightly"] }
  lp.queue          #=> "low"
  lp.args           #=> ["nightly"]
  lp.paused?        #=> false
  lp.tz_name        #=> "Asia/Tokyo" or nil
  lp.next_fire_at   #=> epoch seconds
  lp.last_fired_at  #=> epoch seconds, or nil if never fired
  lp.history        #=> [[fired_at, jid], …] newest first
end

loops.fetch(lid)    #=> Loop, or nil
```

`LoopSet#each` re-reads Redis on every iteration; it's sized for the dashboard's
list view, not for a hot loop.

---

## Leader election and the single-fire guarantee

Every worker process starts a cron poller, but `Poller#tick` returns
immediately unless the process holds the cluster lock — it doesn't even iterate
the LoopSet. That single-leader invariant is what gives you one enqueue per
(loop, tick) across the whole swarm.

The lock lives at the `dear-leader` Redis key with a 30s TTL (see
`lib/wurk/leader.rb`): the leader renews every 15s, followers re-check every
60s. `Component#leader?` caches the answer for ~5s so a one-minute tick doesn't
double Redis traffic.

Consequences worth internalizing:

- **Leader death costs up to ~60s** of leaderless time. Ticks in that gap are
  not backfilled.
- **A quieted leader keeps firing.** `SIGTSTP` stops that process *fetching*;
  the cron poller is intentionally left running. Only a full shutdown
  (`SIGTERM`) terminates it. That matches Sidekiq Enterprise.
- **Opt a process out** of ever leading with `WURK_LEADER=false` (or its alias
  `SIDEKIQ_LEADER=false`) — useful for hot-standby pools.
- Election is best-effort, not Raft. A partitioned ex-leader can briefly
  co-exist with a new one until the TTL lapses. If a duplicate run would be
  harmful, make the job idempotent or combine it with unique jobs
  (`sidekiq_options unique_for:`).

---

## Ticks, downtime, and missed windows

The poller sleeps one interval (60s) *before* its first tick, so a short-lived
process exits without ticking and a freshly-elected leader isn't hit by a burst
at boot.

On each tick, for each unpaused loop the poller reads the `nf` mark, fires if
`nf <= now`, then computes the following fire from **now** — not from the missed
slot. So after downtime:

- Each due loop fires **once**, immediately, on the first leader tick after
  recovery.
- The ticks you missed in between are **not** backfilled, however long you were
  down.
- If the fire is more than 90s late, the poller logs a warning:
  `[cron] missed tick lid=… klass=… expected_at=… fired_at=… drift=…s`.

A loop with no `nf` yet (just registered) computes its first fire from
`now - tick_interval`, so a schedule that matched in the preceding minute can
fire on the very first tick after registration.

If a schedule can never match again within ~4 years of lookahead (`0 0 29 2 *`
landing outside any leap year, say), `next_fire_at` returns nil, the `nf` mark
is cleared, and the loop stops firing silently.

---

## Job payloads and ActiveJob

A plain Sidekiq/Wurk job is pushed as `{"class", "args", "queue", "retry"}` with
the loop's configured values.

If the class name resolves to an `ActiveJob::Base` subclass, the poller enqueues
through the AJ adapter with `perform_later(*args)` instead, so callbacks and
argument serialization run normally. Two differences apply on that path:

- `retry:` is ignored — AJ's `retry_on` / `discard_on` govern retries.
- The queue is only overridden when the loop set one explicitly. A loop left at
  the default `"default"` queue defers to the job's own `queue_as`.

---

## Pausing, running now, and history

The dashboard's **Cron** tab lists every loop with its schedule, class, queue,
last fire, next fire, and status. Per-row actions (hidden in read-only mode):

| Action | Endpoint | Effect |
|---|---|---|
| Pause / Unpause | `POST <mount>/api/cron/:lid/pause` \| `/unpause` | Writes `paused` on the loop HASH; a paused loop is skipped by the poller and shows no next fire |
| Enqueue | `POST <mount>/api/cron/:lid/enqueue` | Pushes one run now with the loop's klass/args/queue/retry. Does **not** touch the fire marks or history |
| (row click) | `GET <mount>/api/cron/:lid/history` | The last 25 `[fired_at, jid]` fires |

The same operations are available in Ruby via
`Wurk::Web::Enterprise::Periodic.pause/unpause/enqueue_now/history/list/fetch`.

For tests and ops there is also `Wurk::Cron.fire!(lid)`: it bypasses both the
leader gate and the due-check, enqueues, records history, and advances the fire
marks exactly like a real tick. It returns the jid, or nil for an unknown lid.

There is **no delete action** — not in the dashboard, not in the API. Removing a
loop is `Wurk::Cron.unregister(lid)`, which drops it from the `periodic` set and
deletes its hash and history.

---

## Deploys: what happens when a schedule changes

This is the part that surprises people, so read it before you ship your first
schedule change.

The `lid` is derived from schedule + class + options. Change any of them and you
get a **different loop**, registered alongside the old one:

- **Edited a schedule** (`"0 4 * * *"` → `"0 5 * * *"`)? The new loop is
  registered; the old one stays in Redis and keeps firing on the old schedule.
- **Deleted a `register` line?** Nothing removes it. It keeps firing.
- **Renamed the job class or changed `args`/`queue`/`retry`?** Same story.

Nothing prunes orphans automatically. Clean up explicitly — either from a
console after the deploy, or from the same initializer before you register:

```ruby
# one-off, from `rails runner`, once the new workers have booted and registered
Wurk::Cron::LoopSet.new.each do |lp|
  next unless lp.klass == "NightlyJob" && lp.schedule == "0 4 * * *" # the stale one
  Wurk::Cron.unregister(lp.lid)
end
```

The second surprise: **registration resets the paused flag.** `register` writes
the whole loop hash, including `paused => "0"`, so a loop you paused in the
dashboard un-pauses on the next worker boot unless you registered it with
`paused: true`. Treat the dashboard pause as an incident tool, not a
configuration mechanism.

---

## Validating the schedule at boot

`ConfigTester#verify` runs your periodic block against a disposable Manager and
resolves every class name, so a typo surfaces in CI instead of on the first tick
in production:

```ruby
# config/initializers/wurk.rb
PERIODIC_JOBS = lambda do |mgr|
  mgr.register("*/5 * * * *", "ReportJob")
end

Wurk.configure_server { |config| config.periodic(&PERIODIC_JOBS) }
```

```ruby
# test/periodic_config_test.rb
Wurk::Cron::ConfigTester.new.verify(&PERIODIC_JOBS)  # raises ArgumentError on a bad cron or class
```

`verify` persists loops as it registers them (that is what `register` does), so
on failure it rolls the whole batch back with `unregister` before re-raising —
a half-applied schedule never survives a validation error.

Unlike Sidekiq Enterprise there is no separate `sidekiq-ent/periodic/testing`
file to require; `ConfigTester` ships loaded with the rest of `Wurk::Cron`.

---

## Migrating

### From `sidekiq-cron`

Drop `config/schedule.yml` and the gem; move each entry into a
`config.periodic` block. There is no `Sidekiq::Cron::Job` shim by design — real
Sidekiq never defined that constant, so faking it would break the drop-in
contract and collide with the gem itself.

| `sidekiq-cron` | Wurk |
|---|---|
| `cron:` | first argument to `mgr.register` |
| `class:` | second argument |
| `queue:` | `queue:` |
| `args:` | `args:` |
| `name:` | no equivalent — loops are keyed by `lid`, not a name |
| `Sidekiq::Cron::Job.create/destroy` | `mgr.register` / `Wurk::Cron.unregister(lid)` |
| `Sidekiq::Cron::Job.all` | `Wurk::Cron::LoopSet.new` |
| natural-language / 6-field schedules (fugit) | not supported — use 5-field crontab |

If you'd rather keep the gem, you can: its upstream suite runs against Wurk in
the ecosystem CI job. The native path is recommended — fewer dependencies,
first-class dashboard support.

### From `sidekiq-scheduler`

Same shape. `every: '5m'` style intervals have no equivalent; express them as
crontab (`*/5 * * * *`). `sidekiq-scheduler`'s `enabled: false` maps to
`paused: true`, and its `description` has no counterpart.

---

## Gotchas

- **`args` is static.** It's serialized into Redis once at boot. `args: [Date.today]`
  freezes the date of the deploy, forever.
- **Registration happens in server processes only.** If no worker has booted
  since you added a loop, it isn't in Redis and the dashboard won't show it.
- **Loops persist across deploys** and outlive the code that registered them.
  See the deploy section above.
- **A dashboard pause is undone by the next boot** unless the loop is registered
  with `paused: true`.
- **Enqueue-now doesn't move the schedule.** The next scheduled fire happens as
  planned.
- **History is capped at 25 fires** per loop and holds only `[fired_at, jid]`.
  It is not an audit log — the job's own outcome lives in the normal
  processed/failed metrics.
- **`Wurk::Cron.reset!` wipes every loop in the cluster.** It's a test helper;
  never call it from production code.

---

## Related

- [Migrating from Sidekiq](migrate-from-sidekiq.md) — §6 covers the
  gem-by-gem mapping including `sidekiq-cron`.
- [Dashboard](dashboard.md) — mounting, read-only mode, extension tabs.
- [Running Wurk](running.md) — swarm, standalone, and embedded modes.
