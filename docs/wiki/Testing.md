# Testing jobs

The `Sidekiq::Testing` harness ships inside the gem — nothing extra to require, and `Sidekiq::Testing`, `Sidekiq::Queues` and the per-class job helpers are all aliased, so an existing suite keeps working on the gem swap.

## The three modes

| Mode | Setter | What a push does |
|---|---|---|
| `:disable` | `Sidekiq::Testing.disable!` | Real Redis write. **This is the default.** |
| `:fake` | `Sidekiq::Testing.fake!` | Payload collected in the in-memory store; nothing runs |
| `:inline` | `Sidekiq::Testing.inline!` | Job runs synchronously in the calling thread, at push time |

```ruby
# test/test_helper.rb
require "wurk/testing"
Sidekiq::Testing.fake!

# test/models/order_test.rb
def test_confirming_enqueues_a_receipt
  assert_difference -> { ReceiptJob.jobs.size }, 1 do
    order.confirm!
  end
  Sidekiq::Testing.inline! { order.confirm! }   # or run it for real, here
end
```

The mode is read in `Wurk::Client#raw_push`, the one funnel every enqueue path goes through, so `perform_async`, `perform_in`, `perform_bulk`, `Sidekiq::Client.push`, `push_bulk` and the Active Job adapter all honour it.

Block form is thread-local and scoped; the no-block form is process-global. Nesting block forms raises `TestModeAlreadySetError`, matching Sidekiq 8.

## Inline is not the real processor

`:inline` (and `drain` / `perform_one`) calls `process_job`, which runs `perform` through `Sidekiq::Testing.server_middleware` — a **separate, empty-by-default chain**, not your configured server chain. Add to it explicitly if a test needs your middleware. Client middleware, by contrast, runs in every mode.

Absent from the inline path, because `Wurk::Processor` is not involved:

- **No retry.** The exception propagates straight into your test; nothing hits the retry set, and `sidekiq_retry_in` / `sidekiq_retries_exhausted` / death handlers never fire.
- No job logging, no stats, no `WorkSet` entry, no heartbeat.
- No interrupt handling — iterable jobs run to completion rather than yielding.

## The sharpest edge: testing modes intercept the push, and nothing else

Anything implemented as a direct Redis call is untouched by them.

| Feature | Under `:fake` / `:inline` |
|---|---|
| `Sidekiq::Batch` | Creation, `bid` metadata, `linger` all write to **real Redis** — a connection is required even in `:fake` |
| Batch callbacks | **Never fire.** They are driven by the server-side completion path that inline bypasses |
| Unique jobs | The lock is taken against real Redis *before* the test hook, so duplicates are suppressed — and the lock outlives the test unless you flush |
| Limiters | Called from inside your job body; the mode is irrelevant |
| `Queue`, `RetrySet`, `ScheduledSet`, `DeadSet`, `Stats` | Read real Redis; they never see the fake store |

So point the test environment at a real, isolated Redis database even in `:fake` mode, and flush between tests. Batch and unique-job assertions belong in a real-Redis tier.

**Also worth knowing:** under Rails' test environment the swarm never boots, so nothing you push to Redis from a test will ever be picked up by a worker — execution is always something you do explicitly. And because the fake store is process-global, a *thread*-parallel runner shares it; use the block form and don't assert across threads.

Per-class and cross-class helpers, `drain`/`perform_one`, scheduled-job assertions, RSpec setup, real-Redis integration tests, and migrating an existing Sidekiq suite: **[docs/testing.md](https://github.com/developerz-ai/wurk/blob/main/docs/testing.md)**.
