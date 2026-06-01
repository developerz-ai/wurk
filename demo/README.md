# Wurk demo app

The Rails 8 app behind [wurk.demo.developerz.ai](https://wurk.demo.developerz.ai).
It runs Wurk as its job backend, mounts the dashboard **read-only**, and runs a
producer (`app/workloads/producer.rb`) that continuously exercises every surface:

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
bin/rails runner 'Wurk::Swarm.new(topology: Wurk.configuration.topology).tap(&:boot).supervise' &

# web (read-only dashboard + producer)
WURK_DEMO=1 WURK_DISABLED=1 bin/rails server
# → open http://localhost:3000/wurk
```

Deploy is described in [../docs/demo-deploy.md](../docs/demo-deploy.md).
