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

## Optional soak traffic

The soak workload (`app/workloads/demo_soak.rb`, jobs in
`app/jobs/soak_job.rb`) is **additive and opt-in**, not a replacement for
`DemoProducer`. The ordinary showcase still maintains its Retries target of 4
and Dead target of 5 and uses the unchanged `high`, `default`, `low` worker
queues. With soak unset or anything other than exactly `1`, ordinary demo
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

Each admitted cycle exercises retries that eventually succeed, delayed
scheduling, cron, a batch with both complete and success callbacks, unique-job
deduplication, and bucket limiting. Soak failures are recoverable rather than
permanent additions to the showcase Dead set.

It also requests a bounded restart of **one** registered worker through Wurk's
process-control mechanism. Swarm supervision replaces that worker; reliable
fetch preserves private-list work for reclamation. Recovery means executing
the original tagged job/JID after restart, not simply issuing a stop request.
This is not a swarm-wide restart and web must never signal foreign OS PIDs.

Dashboard probes are fixed local **GET** requests through the Rails-mounted
`/wurk/api` routes, not requests to the public demo, user-selected URLs, or
`Wurk::Web.call` (which serves extensions, not the dashboard API). They do not
retry, clear, delete, or otherwise mutate dashboard data. Read-only mode stays
on.

### Bounds and error reporting

The producer waits 60 seconds between cycle attempts. Admission requires fewer
than 40 total queued jobs across `high`, `default`, and `low` plus retry and
scheduled entries, and fewer than 10 tracked soak batches. Each admitted cycle
submits one retry job, one job delayed by 2 seconds, two batch members, two
identical unique-job submissions (a 30-second uniqueness window), and three
bucket-limited jobs. It also registers the once-per-minute soak cron. The
bucket permits two jobs per minute; limiter rescheduling is capped at two.

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
production.
These are admission thresholds, not Redis eviction settings. A failed,
missing, or malformed memory probe fails closed: no new soak cycle is
produced. Production can resume after a subsequent valid probe is below the
admission limits and backlog has drained. Existing jobs and ordinary showcase
traffic are not stopped by this soak-only pause.

All soak payloads carry `tags` containing `demo-soak`, including scheduled,
cron, retried and batch jobs and generated callback wrappers. Callback options
preserve the marker too. Demo-only server middleware carries it into the
job's Sentry scope: a payload tag alone is not in Wurk's allow-listed job
context. With error reporting enabled, the demo filter drops marked soak
events while retaining unmarked errors under the existing policy (intentional
`BrokenJob`/`FlakyWebhookJob` failures remain suppressed). The marker is scoped
to soak jobs and their callback wrappers, not all demo traffic.

## Gemfile.lock


`Gemfile.lock` is committed and the image installs it frozen. It pins the
path-sourced `wurk` at `Wurk::VERSION`, so **every version bump must re-lock the
demo** — `bundle exec rake release:relock_demo` from the repo root — or
`rake release:check` refuses the release. Lock with the image's Bundler (the
`BUNDLED WITH` line); the relock task keeps it.

Deploy is described in [../docs/demo-deploy.md](../docs/demo-deploy.md).
