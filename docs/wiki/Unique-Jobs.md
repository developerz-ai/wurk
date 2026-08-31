# Unique jobs

The Sidekiq Enterprise feature, free and in the same gem. Enqueueing takes a Redis lock keyed by a digest of the job; a second push while that lock is held is **dropped** rather than enqueued. `Sidekiq::Enterprise.unique!`, `unique_for:`, `sidekiq_unique_context` and `Sidekiq::Enterprise::Unique.locked?` are the Enterprise names, and the `unique:<sha256>` key layout is unchanged — locks written by Sidekiq Enterprise are honoured by Wurk and vice versa.

It is **best-effort dedup at enqueue time, not a distributed mutex.**

```ruby
# config/initializers/wurk.rb — required, in every process that enqueues AND every one that works
Sidekiq::Enterprise.unique!

class ChargeJob
  include Sidekiq::Job
  sidekiq_options unique_for: 10.minutes, unique_until: :success

  def perform(account_id, cents) = Billing.charge!(account_id, cents)
end

ChargeJob.set(unique_for: false).perform_async(1, 2_500)   # per-call opt-out
```

`unique_until: :success` holds the lock across the whole retry chain and releases when `perform` returns; `:start` releases just before `perform` runs, so a duplicate can be enqueued mid-run. Every release is an atomic compare-and-delete in Lua, so a late retry can never release a fresh lock taken by someone else.

## The failure mode is silence

Nothing here raises, warns, or shows up in the dashboard — there is no lock view at all.

- **No `unique!` call ⇒ `unique_for:` is ignored.** Silently. The middleware is only installed by that call.
- **No `unique_for:` on the class ⇒ no lock.** There is no default TTL; uniqueness is opt-in per worker.
- **A dropped push returns `nil`** instead of a jid — `perform_bulk` returns `nil` in that slot. `MyJob.perform_async(x).then { … }` will `NoMethodError` the first time dedup actually works.

## The digest is `[class, queue, args]`

Which means the queue is part of the identity (the same job on `default` and `critical` are two locks), args are compared post-JSON (`1` ≠ `"1"`), and **one timestamp or UUID in the args defeats dedup entirely**. Narrow it with a class method:

```ruby
def self.sidekiq_unique_context(job)
  ["SyncJob", job["queue"], [job["args"].first]]   # ignore the trailing options hash
end
```

That hook is skipped if the class isn't loaded in the pushing process — an enqueue-only process would then compute a *different* key than the worker. Load the class on both sides. Active Job payloads are narrowed for you (the per-push `job_id` / `enqueued_at` fields are dropped), so `unique_for:` works on an AJ class as-is.

## Gotchas

**Long TTLs are what hurt.** A crash leaves the lock behind until it expires and nothing can shorten that, so a 24-hour `unique_for` plus one `SIGKILL` is a day of silently dropped pushes. Keep it to minutes. Relatedly, if your retry backoff can outlast `unique_for` under `:success`, the lock expires mid-chain and a duplicate becomes enqueueable.

**A manual kill retains the lock** (Enterprise parity: an operator removing a job shouldn't have it re-enqueued a second later), while automatic death releases it. Delete the key yourself to get it back sooner.

**`encrypt: true` + `unique_for:` is refused.** Encryption rewrites the last argument with a fresh IV per push, so no two pushes ever digest the same. Wurk raises `Wurk::Unique::ConfigurationError` rather than let the silent mis-dedup through, which is stricter than Enterprise.

**Different question, different tool.** For "collapse a burst" use `collapse: { policy: :debounce | :throttle }` — debounce keeps the *last* payload once the burst goes quiet, throttle keeps the *first* per epoch-aligned slot. For "only one running at a time" use a `Sidekiq::Limiter.concurrent` inside `perform`; a unique lock does not provide runtime mutual exclusion.

Release table, scheduled/retry/batch interaction, testing under fake and inline, the `collapse:` options, and the `sidekiq-unique-jobs` migration map: **[docs/unique-jobs.md](https://github.com/developerz-ai/wurk/blob/main/docs/unique-jobs.md)**.
