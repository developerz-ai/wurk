# Wurk demo app

The Rails 8 app behind [wurk.demo.developerz.ai](https://wurk.demo.developerz.ai).
It runs Wurk as its job backend, mounts the dashboard **read-only**, and runs a
producer (`app/workloads/demo_producer.rb`) that continuously exercises every surface:

- `WelcomeJob` — plain `perform_async` across queues (throughput)
- `DailyReportJob` — periodic/cron (leader-fired)
- `SendReceiptJob` — unique job (`unique_for:`)
- `ExportChunkJob` + `ExportCallback` — a batch with success/complete callbacks
- `ThrottledApiJob` — rate-limited via a bucket limiter
- `FlakyWebhookJob` — fails + retries
- `BrokenJob` — straight to the dead set

## Run it locally

```sh
cd demo
bundle install
bin/rails db:prepare

# worker (drains jobs)
WURK_DEMO=1 WURK_DISABLED=1 WURK_COUNT=2 \
  bin/rails runner 'Wurk::Swarm.new(topology: Wurk.configuration.topology).tap(&:boot).supervise' &

# web (read-only dashboard + producer)
WURK_DEMO=1 WURK_DISABLED=1 WURK_DEMO_PRODUCER=1 bin/rails server
# → open http://localhost:3000/wurk
```

`WURK_DEMO_PRODUCER=1` starts the traffic producer thread; set it only on the
web process, never on the worker (the swarm parent forks, and a Redis-holding
thread must not be forked). `bin/demo-entrypoint` does this for the image.

## Dormant demo fault canary

`DemoCanaryJob` is a demo-only fault probe, dormant by default. `perform` returns
nil unless `WURK_DEMO_CANARY` equals exactly `'1'`; only then does it raise
`DemoCanaryJob::CanaryFault` with the message
`DEMO-ONLY CANARY: DemoCanaryJob fault probe`. It has zero retries (`retry: 0`),
no I/O or SDK dependency, and no enqueue, producer, cron, or schedule integration.
Reporting belongs to the existing Wurk Sentry middleware, not the job.

The canary flag does not enable reporting. The independent reporting gate still
requires `WURK_DEMO_REPORT_ERRORS` to equal `'1'` and a nonblank `SENTRY_DSN`.
Surviving canary events receive `canary=demo_fault` alongside existing tags;
they are not classified as intentional failures or soak events. Soak-marked
canary events are still dropped, and normal credential/PII scrubbing and
fail-closed handling remain active.

This PR does not arm or deploy the canary. Any later canary repair must remain
under `demo/`, use the `chore(demo):` commit prefix, and require no gem/version
release.

Run its SDK-double tests from the repository root (no network reporting):

```sh
NCPU=1 bin/rake test:unit TEST=demo/test/demo_canary_test.rb
```

The explicit selection is required: default test globs omit `demo/test/`.

## Optional soak traffic

The soak workload (`app/workloads/demo_soak.rb`, jobs in
`app/jobs/soak_job.rb`) is **additive and opt-in**, not a replacement for
`DemoProducer`. The ordinary showcase still maintains its Retries target of 4
and Dead target of 5 and uses the unchanged `high`, `default`, `low` worker
queues in strict `high` → `default` → `low` priority. Soak jobs use `low`.
With soak unset or anything other than exactly `1`, ordinary demo
traffic, error reporting, and the read-only dashboard behave as before.

### Enable or disable

Set `WURK_DEMO_SOAK=1` **only on the web process**. For a local web server,
replace the web command above with:

```sh
WURK_DEMO=1 WURK_DISABLED=1 WURK_DEMO_PRODUCER=1 WURK_DEMO_SOAK=1 bin/rails server
```

The soak producer requires all four flags to be exactly `1`: demo mode,
disabled automatic swarm, web producer, and soak opt-in. It belongs only in the
nonforking web process; worker and passthrough roles must not start it, and
forked children must not inherit an active producer. Workers **execute** soak
jobs but never **produce** soak cycles. Do not enable the flag globally across
both deployment roles. The image entrypoint does not opt into soak for you.

To disable, unset `WURK_DEMO_SOAK` on web and restart/roll out web. Already
queued, scheduled, retried, or executing jobs can finish on workers; disabling
the producer is not a queue purge. Keep the existing hourly reset unchanged.

### What a cycle exercises

Admission starts a bounded exercise of retries, delayed scheduling, cron
enqueue/execution, two batch members with both complete and success callbacks,
unique-job deduplication, and bucket-limiter rescheduling. Admission is not proof
of successful execution: verify the retry and scheduled jobs complete, the cron
job runs, both batch members and both callbacks run, duplicates are suppressed,
and limited work is rescheduled and completes. A cycle returning `true` is not
proof that its recovery exercise succeeded. Soak payloads allow at most two
retries with `dead: false`, rather than permanent additions to the showcase
Dead set.

The recovery exercise coordinates an in-flight soak job with a restart of
**one** eligible registered worker through Wurk's process-control mechanism.
The worker must have tag `demo`, be nonembedded and not stopping, and have a
heartbeat newer than 30 seconds ago. Only the eligible worker that recorded
starting the original JID may receive the stop request.
With a real supervised swarm, supervision replaces the stopped worker. TERM
shutdown can requeue unfinished private-list work before killing its threads;
TERM alone therefore does not demonstrate orphan reclamation.
The evidence keys are `demo-soak:<token>:started` (the worker identity and
original JID as JSON) and `demo-soak:<token>:recovered` (that same JID), both
with a 300-second TTL. The `[demo-soak] recovery <jid>: verified` log records
only that JID comparison; a missing log or `not observed` does not verify recovery.
A supervised-restart regression must additionally observe a different worker
identity, completion of the original `demo-soak`-tagged JID, and its removal
from queued and private-list fetch custody. A stop request, replacement heartbeat,
or completion of a newly enqueued substitute is insufficient. The same-child
Manager/Processor recovery test does not demonstrate swarm replacement.
The producer waits at most 5 seconds for the job to start and then at most
50 seconds for recovery evidence, with no substitute-job retry loop. These waits
stay within the soak workload's budgets. An unavailable worker, bounded failure,
or completion timeout does not verify recovery and must not cause more recovery
jobs to be added. This is not a swarm-wide restart, and web must never signal
foreign OS PIDs.

Dashboard probes are fixed local **GET** requests through the Rails-mounted
`/wurk/api/{stats,queues,retries,scheduled,dead,processes,batches,limiters,cron}`
paths at `127.0.0.1` on `PORT` (default 3000). They never follow redirects or
request the public demo, user-selected URLs, or `Wurk::Web.call` (which serves
extensions, not the dashboard API). They do not retry, clear, delete, or
otherwise mutate dashboard data. Read-only mode stays on.

### Bounds and error reporting

The producer waits 60 seconds after each cycle attempt. Admission counts queued
jobs across `high`, `default`, and `low` plus retry and scheduled entries,
reserves 12 slots for the cycle (including callback wrappers and recovery), and
requires the resulting total to remain below 40, with fewer than 10 tracked
soak batches. Each admitted cycle submits a retry job, a job delayed by
2 seconds, two batch members, two identical unique-job submissions (a 30-second
uniqueness window), and three bucket-limited jobs, alongside bounded recovery
work. Cron uses the real enqueue path with an unpersisted loop whose schedule
expression is `* * * * *`: each cycle explicitly fires it after admission,
without registering autonomous leader traffic that could bypass later pressure
checks. That expression does not schedule independent minute-by-minute fires.
Enqueueing alone establishes neither cron history nor successful job execution;
verify the tagged cron job's execution separately. The bucket permits two jobs
per minute; limiter rescheduling is capped at two.

Bookkeeping keys, batch expiry/linger, and limiter retention use a 300-second
TTL. Expired tracked batches are pruned from the indexes on subsequent backlog
checks. At most one eligible worker receives a stop request per admitted cycle.
Each fixed dashboard GET has 1-second connect, read, and write timeouts; only
HTTP 200 with a JSON object or array is accepted. A failed probe prevents cycle
admission. These limits live in `app/workloads/demo_soak.rb` and
`app/jobs/soak_job.rb`; do not raise showcase targets to compensate.

Before admitting more work, the producer checks Redis memory pressure. The
admission ceiling is the smaller of **80% of configured `maxmemory`** and
**128 MiB** (134,217,728 bytes). When `maxmemory` is zero, the ceiling is
128 MiB. `used_memory` must be strictly below the ceiling; equality pauses
production. These are admission thresholds, not Redis eviction settings. A failed,
missing, or malformed memory probe fails closed: no new cycle is admitted,
including its cron submission. Memory and backlog checks admit new cycles;
they do not cancel previously admitted work or prevent its retries, limiter
reschedules, or callbacks from draining. No persistent soak cron registration remains to
produce outside the guarded cycle. Production can resume after a subsequent
valid probe is below the admission limits and backlog is within bounds.
Already queued, scheduled, retried, or executing work may drain on workers;
this soak-only pause is not a purge and does not stop ordinary showcase traffic.

All soak payloads carry `tags` containing `demo-soak`, including scheduled,
cron, retried and batch jobs and generated callback wrappers. Callback options
preserve the marker too. Demo-only server middleware bridges the payload marker
to the job's Sentry scope as `demo-soak=soak`: the central `DemoSentryPolicy`
recognizes a tag key or value equal to `soak` after trimming and lowercasing,
not `demo-soak=true`. Payload tags alone
are not in Wurk's allow-listed job context. The scoped marker must remain visible
when the error is captured, without leaking into subsequent unmarked jobs.

Error reporting still requires exactly `WURK_DEMO_REPORT_ERRORS=1` and a nonblank
`SENTRY_DSN`. The central policy drops marked soak events and intentional
`BrokenJob`/`FlakyWebhookJob` failures; unmarked errors retain the existing PII
protection and credential scrubbing. Soak suppression neither replaces that
policy nor disables reporting for all demo traffic.

## Gemfile.lock

`Gemfile.lock` is committed and the image installs it frozen. It pins the
path-sourced `wurk` at `Wurk::VERSION`, so **every version bump must re-lock the
demo** — `bundle exec rake release:relock_demo` from the repo root — or
`rake release:check` refuses the release. Lock with the image's Bundler (the
`BUNDLED WITH` line); the relock task keeps it.

Deploy is described in [../docs/demo-deploy.md](../docs/demo-deploy.md).
