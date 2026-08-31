# Wurk extras

> **Everything on this page is Wurk-only — using it ties you to Wurk.** These four surfaces have no Sidekiq equivalent, so a job that depends on one cannot go back to stock Sidekiq, Pro or Enterprise without you rebuilding the mechanism by hand. Every one is off until you opt in, and none of them changes the wire format of a job that does not use them. The rest of the wiki is drop-in; this page is the exception, deliberately.

## Flows — DAG orchestration

Fan out, fan in, and run a node only once everything it depends on has succeeded — the ground BullMQ's `FlowProducer`, Oban Pro Workflows and Celery's `chord` cover.

```ruby
Wurk::Flow.new do |f|
  a = f.job(FetchJob, "https://a")
  b = f.job(FetchJob, "https://b")
  f.job(MergeJob, depends_on: [a, b])   # runs after both succeed
end.run
```

A node is one job wrapped in its own [batch](https://github.com/developerz-ai/wurk/blob/main/docs/batches.md), so nothing new counts jobs and the dashboard already knows how to render it. One job per node means unbounded fan-out belongs *inside* a node (open a batch there), not as thousands of sibling nodes. Closest Sidekiq Pro gets is a batch: fan-out with one completion callback, no dependency edges. **[docs/flows.md](https://github.com/developerz-ai/wurk/blob/main/docs/flows.md)**

## Job status, progress and results

Stock Sidekiq forgets a job the moment it finishes — no lookup by jid, no progress outside batches, no record of the return value. `track: true` gives you all three.

```ruby
class ImportJob
  include Wurk::Worker
  sidekiq_options track: true

  def perform(file_id)
    rows.each_with_index { |row, i| import(row); status.at(i, rows.size, "row #{i}") }
  end
end

Wurk::Status.get(jid).then { |r| [r.state, r.progress, r.total, r.result] }
```

States are `enqueued → running → complete | interrupted | failed → retrying | dead`. Rows live on a re-stamped `status_ttl` (30 min default), so there is no sweeper and no unbounded key growth — and no history either: **a status is an in-flight view, not an audit log.** An untracked class costs one Hash lookup and a `yield`; a tracked one rides the pipeline the client already had open. **[docs/job-status.md](https://github.com/developerz-ai/wurk/blob/main/docs/job-status.md)**

## OpenTelemetry tracing

A producer span on enqueue whose W3C trace context rides the job hash across Redis, and a consumer span when a worker picks it up — so enqueue-to-execute is one trace, across the fork.

```ruby
Wurk.configure_server { |config| config.telemetry = true }
```

Needs `opentelemetry-api` loaded; it is deliberately not a gemspec dependency, and with either half missing tracing stays off rather than raising. A job that waits out a long backoff or a scheduled set starts its own trace with a **link** back instead of stretching one trace across hours. **[docs/telemetry.md](https://github.com/developerz-ai/wurk/blob/main/docs/telemetry.md)**

## The HTTP API (`/v1`)

A polyglot producer surface over the same Redis: a Python, Go or Node service `POST`s a job and a Ruby — or stock Sidekiq — worker runs it. Same keys, same JSON, nothing invented at the boundary.

```ruby
# not inside configure_server: a Puma web process never enters server mode
Wurk.configuration.api_token ENV.fetch("WURK_API_TOKEN"), scopes: %i[enqueue read]
```

**Off unless a token is registered** — with none, no route is mounted and `/wurk/api/v1` 404s like any unmounted path rather than issuing a bearer challenge for a surface that isn't there. Scopes are `enqueue` (`POST /jobs`, `/jobs/bulk`), `read` (every `GET`) and `admin` (pause/unpause a queue, quiet/stop a process). Note `GET /jobs/:jid` answers from `Wurk::Status`, so it needs `track: true` — untracked, unknown and expired all read as `404 job_not_found`, because Redis holds nothing that tells them apart. `GET /health` is for monitoring, not for a Kubernetes probe: a probe must never carry a bearer token — use `config.health_check(port:)`. **[docs/api-http.md](https://github.com/developerz-ai/wurk/blob/main/docs/api-http.md)**
