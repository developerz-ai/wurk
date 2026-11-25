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
`Sidekiq::CronParser` → `Wurk::Cron::Parser`. `Sidekiq::Cron` is **not** an
alias of these: that namespace belongs to the `sidekiq-cron` gem. When the gem is
bundled Wurk leaves it alone; when it is not, `Sidekiq::Cron` is Wurk's native
sidekiq-cron ([below](#sidekiq-cron-natively-sidekiqcron)), so an app can drop
the gem and keep its `Sidekiq::Cron::Job` code and its Redis state.

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

`configure_server` only yields in server processes, and the block's registrations
are written to Redis when that server boots (the launcher, before the cron poller
starts) — not while your initializers load, and not from a process that never
boots a server. So a periodic block may sit in any initializer, ahead of or after
`config.redis =`. Multiple `config.periodic` blocks accumulate onto one shared
Manager.

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

`register` returns the `Wurk::Cron::Loop`. Inside `config.periodic` it is
persisted when the server boots; a standalone `Wurk::Cron::Manager.new` persists
it immediately. An invalid cron string or an empty/non-String class name raises
`ArgumentError` right there, from the `register` call.

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

Changing only a loop's `tz:` keeps its lid, so the loop keeps its stored next
fire: that one occurrence runs on the old zone's clock, and every later one on
the new zone's.

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
`lib/wurk/leader.rb`): the leader renews every 15s, and a follower re-checks when
the lease it last read runs out, at most 60s later. `Component#leader?` caches the
answer for ~5s so a one-minute tick doesn't double Redis traffic.

Consequences worth internalizing:

- **Leader death costs up to about 31s** of leaderless time: what is left of the
  lease (15-30s after a `SIGKILL`) and about a second. The lock itself is untouched,
  so nobody can win it earlier. A graceful shutdown releases it at once.
- **A new leader ticks the moment it wins**, not at its poller's next minute, so a
  gap costs at most the occurrences that were more than 90s late by then, and those
  are not backfilled.
- **A full Redis does not cost the lease.** The renewal goes through an `allow-oom`
  script, like the heartbeat. Occurrences due meanwhile are refused like any other
  enqueue and fire when memory returns, if still inside the grace. Dragonfly compiles no such
  script: there the renewal is refused, the lease lapses, and a leader is elected
  once memory returns.
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

The poller sleeps one interval (60s) *before* its first tick, unless its process wins
the lock first, so a process that never leads exits without ticking.

On each tick, for each unpaused loop the poller reads the `nf` mark, fires if
`nf <= now`, then computes the following fire from **now** — not from the missed
slot. So after downtime:

- Each due loop fires **once**, immediately, on the first leader tick after
  recovery, if an occurrence falls inside the grace (90s by default).
- The ticks you missed in between are **not** backfilled, however long you were
  down. A slot past the grace is logged and dropped:
  `[cron] missed tick lid=… klass=… expected_at=… now=… drift=…s — skipped, not backfilled`.
  An occurrence still inside the grace fires in its place, so a minutely loop never
  loses the tick. A daily loop whose time passed outside the grace waits for tomorrow.
- **Exactly one fire per claim.** `loops:<lid>`'s `nf` is claimed by compare-and-swap,
  so two leaders co-existing for a few seconds cannot both fire. A Redis restored from
  a snapshot older than the last fire rewinds `nf` too, and the occurrence inside the
  grace can then fire a second time: that is the one case the claim cannot see.

To let a slot fire later than 90s, set a grace for the whole cluster's pollers, for a
cut-over from `sidekiq-cron` (`reschedule_grace_period`, 300s by default there) or a
slow deploy:

```ruby
config.periodic do |mgr|
  mgr.grace = 300
  mgr.register('0 4 * * *', 'NightlyJob')
end
```

It never goes below 1.5 ticks: a raised tick interval must not turn every on-time fire
into a missed one.

A loop with no `nf` yet (just registered) computes its first fire from
`now - tick_interval`, so a schedule that matched in the preceding minute can
fire on the very first tick after registration.

If a schedule can never match again within ~4 years of lookahead (`0 0 29 2 *`
landing outside any leap year, say), `next_fire_at` returns nil, the `nf` mark
is cleared, and the loop stops firing silently.

---

## Job payloads and ActiveJob

A plain Sidekiq/Wurk job is pushed as `{"class", "args", "queue", "retry"}` with
the loop's configured values laid over the worker's own `sidekiq_options`, as
`perform_async` would. That needs the class, so the leader skips a loop whose
class it cannot load (see [Deploys](#deploys-what-happens-when-a-schedule-changes)).

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
get a **different loop** — so registration prunes the ones it supersedes.

After a `config.periodic` block registers, Wurk removes every loop in the
registry whose `klass` matches a class that block registered and whose `lid`
isn't one it just wrote. So:

- **Edited a schedule** (`"0 4 * * *"` → `"0 5 * * *"`)? The old loop is pruned
  on the next worker boot. Only the new schedule fires.
- **Changed `args`/`queue`/`retry`?** Same — superseded, pruned.
- **Deleted the `register` line entirely?** **Not** pruned. Nothing in the
  surviving code mentions that class, so no scope can see it. While the class
  still exists, it keeps firing. Once the class is gone too (deleted, renamed, or
  a rollback to code that predates it), the leader skips each occurrence: it
  logs `[cron] class … is not defined in this process … occurrence skipped` and
  hands a `Wurk::Cron::UnknownWorkerClass` to your error handlers once per loop
  per process. Nothing is pushed, so a vanished class cannot turn into a retry
  storm. Remove the loop explicitly, or end your periodic block with
  `mgr.authoritative!`, which deletes every loop that block did not register.

Pruning is scoped by class precisely so it stays safe: a process that registers
only some of your loops never touches the others, and a process that registers
none — a client-only or web process — deletes nothing.

```ruby
# a deleted register line still needs a manual removal, once, after deploy
Wurk::Cron::LoopSet.new.each do |lp|
  next unless lp.klass == "RetiredJob"
  Wurk::Cron.unregister(lp.lid)
end
```

> **Two registrars that disagree about one class will flap.** If process A
> registers `K` on one schedule and process B registers `K` on another, each
> boot prunes the other's loop. This includes the window in a rolling deploy
> where an old-code process boots after a new-code one; it converges once only
> one code version is booting. Don't register the same class from two different
> configs.

Pause state belongs to the runtime, not to the code: `paused` is written with
`HSETNX`, so a code-declared `paused: true` is the **initial** value at first
registration, and a pause or unpause from the dashboard survives every
subsequent boot.

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

## sidekiq-cron, natively (`Sidekiq::Cron`)

An app that used the `sidekiq-cron` gem can remove it from the `Gemfile` and keep
everything else: `Sidekiq::Cron::Job.load_from_hash!`, the schedule YAML, the
`Sidekiq::Cron.configure` initializer, `require "sidekiq/cron/web"`, and the
entries already in Redis, with their enabled/disabled state. No import, no data
migration. `Sidekiq::Cron` is `Wurk::SidekiqCron`, autoloaded on first use (or by
`require "sidekiq/cron"` / `require "sidekiq-cron"`).

**How it is built.** A store of its own, in the gem's keyspace, not a layer over
the loops above. A loop is keyed by a hash of its schedule, class and options
(its `lid`); a sidekiq-cron entry is keyed by its **name**, and the gem's pods
read only their own keys. Mapping one onto the other would mean a second copy of
the enable/disable state and a translation while old and new pods overlap, so
the native code reads and writes exactly what sidekiq-cron 2.3/2.4 does, and the
two stores share only the crontab parser and the cluster leader:

| Key | Type | Holds |
|---|---|---|
| `cron_jobs:<namespace>` | SET | the entries' hash keys |
| `cron_job:<namespace>:<name>` | HASH | the gem's 16 `to_hash` fields, `status` (`enabled`/`disabled`) and `last_enqueue_time` among them |
| `cron_job:<namespace>:<name>:enqueued` | ZSET | one member per fired occurrence (ISO-8601 UTC), trimmed to 24 h |
| `cron_job:<namespace>:<name>:jid_history` | LIST | `{jid, enqueued}`, newest first, `cron_history_size` long |

**State is keyed by name.** Only `#enable!` / `#disable!` (or a `status` key in
the data you load) change `status`. Editing an entry's `cron`, `class`, `queue`
or `args` keeps a hand-disabled entry disabled. `load_from_hash!` deletes the
`source: schedule` entries the hash no longer names, as the gem does; an entry
created at runtime (`source: dynamic`) is kept.

**Exactly once.** The poller runs in every process and only the cluster leader's
ticks do anything (`dear-leader`, like the loops). The guarantee is the gem's
own: before pushing, a poller `ZADD`s the occurrence to the entry's `:enqueued`
set, and only the one that added it pushes. The native code adds the same
member the gem does, so during a rollout where old pods run the gem's poller
and new pods run this one, each occurrence is still pushed once.
`test/ecosystem/sidekiq-cron/interop.rb` runs the real gem and the native code
against one Redis in CI: status set through either is seen by the other, both
compute the same occurrence for every schedule shape tested (zones with and
without DST, both 2026 US clock changes), and both pollers ticking through one
minute push one job.

**An unloadable class is skipped, not pushed.** The same guard applies to native
sidekiq-cron entries: if the class named by a fired entry cannot be loaded in the
process (deleted, renamed, or a rollback to code that predates it), the poller
claims the occurrence and skips it. No job is pushed. It logs a WARN naming the
class and the entry, and hands a `Wurk::SidekiqCron::Job::UnknownWorkerClass`
to your error handlers once per entry per process (as the loop guard does).
A vanished class cannot turn into a retry storm, because pushing the bare name
would run with the entry's default retries.

**The gem wins when both are present.** With `sidekiq-cron` in the bundle, Wurk
registers no `Sidekiq::Cron` autoload, its `sidekiq/cron*` files load the gem's,
and the Launcher starts no native poller (asserted by the same interop run).

| sidekiq-cron 2.x | Native |
|---|---|
| `Job.load_from_hash(!)`, `load_from_array(!)`, `.all`, `.count`, `.find`, `.exists?`, `.create`, `.destroy`, `.destroy_all!`, `.destroy_removed_jobs` | same |
| `#enable!`, `#disable!`, `#enabled?`, `#disabled?`, `#status`, `#save`, `#destroy`, `#valid?`, `#errors`, `#enqueue!`, `#to_hash`, `#jid_history_from_redis`, `#last_enqueue_time` | same |
| `Sidekiq::Cron.configure`: `cron_poll_interval`, `cron_history_size`, `reschedule_grace_period`, `default_namespace`, `available_namespaces` (incl. `:auto`), `cron_schedule_file`, `enabled` | same meaning; `cron_poll_interval = 0` starts no poller |
| `natural_cron_parsing_mode`, `cron_poll_process_count` | accepted and validated, no effect (no natural language; only the leader polls) |
| `cron`: 5 fields or `@alias`, trailing IANA zone, month/day names | same |
| `cron` with no zone | the process's local zone (`ENV['TZ']`, else the system's), as fugit; not UTC |
| `cron`: seconds field, natural language (`every day at 5pm`), `L`/`#`, offset zones | not supported: a validation error, returned by `load_from_hash!` and never fired |
| `queue`, `retry`, `args`, `active_job`, `queue_name_prefix`/`_delimiter`, `date_as_argument`, `symbolize_args`, GlobalID args, `description`, `namespace` | same |
| `reschedule_grace_period` (default 60) | same: the newest occurrence fires if it is at most that late |
| `config/schedule.yml` loaded on `:startup` | same, server processes only |
| pre-namespace `cron_jobs` SET | migrated to the default namespace when the poller starts, as the gem does |
| Web tab (`require "sidekiq/cron/web"`) | the dashboard's **Cron** page lists the entries beside the loops, with the name under the class: pause/unpause is `disable!`/`enable!`, plus enqueue-now and history |
| `human_cron` (cronex) | returns the `cron` string |

Compared against fugit: the schedule shapes listed in `interop.rb`, at both 2026
US clock changes. A fixed-time entry inside a repeated or skipped DST hour, in a
shape that list does not hold, has not been.

---

## Migrating

### From `sidekiq-cron`

Two routes. Dropping the gem and keeping its code runs on the native
`Sidekiq::Cron` above, with no data to move. Porting the entries to
`config.periodic` loops is the other: `rake wurk:import:cron` reads
sidekiq-cron's schedule from Redis and registers the same loops (dry run by
default; `APPLY=1` writes). See the migration guide's cutover section. Do not
run both for the same entries: a loop and a sidekiq-cron entry are different
keys, so both fire.

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
- **Loops persist across deploys.** Superseded ones are pruned by class on the
  next registration; a loop whose `register` line was deleted outright is not.
  See the deploy section above.
- **A dashboard pause survives deploys** — `paused` is only initialized from
  code, never overwritten by it.
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
