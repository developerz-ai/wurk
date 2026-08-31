# Periodic, Limiters and Batches

## Periodic (cron) jobs

Leader-elected, so each tick fires **exactly once** across the cluster:

```ruby
Wurk::Cron.register("nightly report", "0 4 * * *", "ReportJob", [], queue: "low")
```

5-field crontab plus `@hourly`/`@daily`/etc., ranges, steps, and per-loop timezones. The dashboard's Cron page shows each loop's schedule and last-fired time.

## Rate limiters

Five strategies (Enterprise parity), wrapped around the work you want to limit:

```ruby
limiter = Wurk::Limiter.bucket("emails", 100, :minute)   # token bucket
limiter.within_limit { Mailer.deliver(...) }
```

`Wurk::Limiter.concurrent`, `.bucket`, `.window`, `.leaky`, and `.points` are all available. On `OverLimit` the server middleware reschedules the job with backoff. The Limiters page shows live usage.

## Batches

```ruby
batch = Wurk::Batch.new
batch.description = "Nightly export"
batch.on(:success, "ExportCallback")   # also :complete and :death
batch.jobs do
  rows.each_slice(1000) { |slice| ExportChunkJob.perform_async(slice) }
end
```

Callbacks fire when the batch succeeds, completes (success or death), or a child dies. Batches nest, and the dashboard's Batches page tracks total/pending/failures and fired callbacks. The callback target receives `new.on_<event>(status, options)`.
