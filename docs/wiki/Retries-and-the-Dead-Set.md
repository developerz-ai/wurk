# Retries and the dead set

A job that raises is stamped with the error, dropped into the `retry` ZSET with a future score, and promoted back onto its queue when the time comes. After enough failures it lands in the `dead` set — the morgue — until you retry it, delete it, or it ages out. Same ZSETs, same score format, same `error_class` / `retry_count` / `failed_at` fields as Sidekiq, and `Sidekiq::RetrySet` / `Sidekiq::DeadSet` / `Sidekiq::JobRetry` are all aliased.

```ruby
class ChargeJob
  include Wurk::Job

  sidekiq_options retry: 5, retry_queue: "low", backtrace: 20

  sidekiq_retry_in do |count, exception, _jobhash|
    case exception
    when RateLimited    then 60 * (count + 1)  # linear instead of the default curve
    when RecordNotFound then :discard          # gone for good; don't bury it
    end                                        # nil ⇒ default formula
  end

  def perform(charge_id) = Charge.find(charge_id).submit!
end
```

Default backoff is `(retry_count ** 4) + 15` seconds plus `rand(10 * (count + 1))` of jitter — so a Redis outage that fails 10,000 jobs at once does not bring all 10,000 back in the same second. The 25 default attempts span **just over 20 days** of wall clock, which is usually longer than the incident window you would actually watch; lower `retry:` per class rather than letting jobs rot.

## `0` and `false` are not the same thing

| `retry:` | On failure |
|---|---|
| `true` (default) | Up to `config[:max_retries]` — 25 |
| `N` | `N` retries, i.e. `N + 1` runs, then the morgue |
| `0` | No retry; the **first** failure runs the full exhaustion path into the morgue |
| `false` | No retry, **no morgue** — death handlers fire and the job is gone |

`retry: false` persists nothing and shows nothing in the dashboard. If you set it, your `config.death_handlers` entry *is* your error reporting.

## Gotchas

**The morgue silently evicts your evidence.** It is trimmed on every write, on two axes: older than `dead_timeout_in_seconds` (180 days) and beyond `dead_max_jobs` (10,000), oldest-first, no per-class quota. A `dead_size` pinned at the cap means you are losing older failures. If you care about a dead job, get it out of the set.

**A `SIGKILL` is not a failure.** The payload never left the process's private list, so it is reclaimed and re-run with no `retry_count` bump and no dead-set entry — which also means no death handler and no signal that it happened, beyond the recovery metric.

**A poison pill never raises, so retries can't catch it.** A job that OOMs or segfaults its worker gets recovered and kills the next one. Wurk counts recoveries per jid at `super_fetch:recovered:<jid>` (72h TTL) and morgues the job on the 3rd — but that kill passes `notify_failure: false`, so **`death_handlers` do not fire for it**. Register `Wurk::Middleware::PoisonPill.on_poison` if you want to be paged.

**`sidekiq_retries_exhausted` runs before the morgue write, `death_handlers` after** — and the global handlers fire on *every* death, including `:discard`, `dead: false` and manual kills (which synthesise `RuntimeError.new("Job killed by API")`, byte-for-byte Sidekiq).

`retry_for:`, `timeout:` / `deadline:`, the full `SortedEntry` and `JobSet` API, the backoff table out to 25 attempts, and the poison-pill callbacks: **[docs/retries.md](https://github.com/developerz-ai/wurk/blob/main/docs/retries.md)**.
