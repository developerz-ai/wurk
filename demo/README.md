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

## Gemfile.lock

`Gemfile.lock` is committed and the image installs it frozen. It pins the
path-sourced `wurk` at `Wurk::VERSION`, so **every version bump must re-lock the
demo** — `bundle exec rake release:relock_demo` from the repo root — or
`rake release:check` refuses the release. Lock with the image's Bundler (the
`BUNDLED WITH` line); the relock task keeps it.

Deploy is described in [../docs/demo-deploy.md](../docs/demo-deploy.md).
