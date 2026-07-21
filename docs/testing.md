# Testing jobs

Wurk ships a `Sidekiq::Testing`-compatible harness in the gem — there is nothing
extra to require. `Wurk::Testing`, `Wurk::Queues`, and the class-level helpers on
your job classes are all aliased under their `Sidekiq::*` names, so an existing
suite that calls `Sidekiq::Testing.fake!` or asserts on `MyJob.jobs.size` keeps
working on the one-line gem swap.

| Alias | Real constant |
|---|---|
| `Sidekiq::Testing` | `Wurk::Testing` |
| `Sidekiq::Queues` | `Wurk::Queues` |
| `Sidekiq::EmptyQueueError` | `Wurk::Testing::EmptyQueueError` |
| `Sidekiq::Job` / `Sidekiq::Worker` | `Wurk::Job` / `Wurk::Worker` |
| `Sidekiq.testing!` / `Sidekiq.testing?` | `Wurk.testing!` / `Wurk.testing?` |

The mode is read by `Wurk::Client#raw_push` — the single place every enqueue path
funnels through — so `perform_async`, `perform_in`, `perform_bulk`,
`Sidekiq::Client.push`, `push_bulk`, and the ActiveJob adapter all honor it
without special-casing.

> **Under Rails' test environment the swarm never forks.** `Wurk::RailsBoot`
> skips boot when `Rails.env.test?` (as it does for `WURK_DISABLED=1` and the
> console), so no worker process will pick up anything you push to Redis from a
> test. Executing a job in a test is always something you do explicitly, with
> one of the modes below.

---

## 1. The three modes

| Mode | Setter | What a push does |
|---|---|---|
| `:disable` | `Sidekiq::Testing.disable!` | Real Redis write. **This is the default.** |
| `:fake` | `Sidekiq::Testing.fake!` | Payload collected in the in-memory `Sidekiq::Queues` store; nothing runs |
| `:inline` | `Sidekiq::Testing.inline!` | Job executed synchronously, in the calling thread, the instant it's pushed |

Predicates: `enabled?` (true in `:fake` or `:inline`), `disabled?`, `fake?`,
`inline?`. `Sidekiq.testing?` is the same as `Sidekiq::Testing.enabled?`.

**No-block form sets the mode process-globally. Block form sets it on the
current thread only, for the duration of the block:**

```ruby
Sidekiq::Testing.fake!                       # global, until changed

Sidekiq::Testing.inline! do                  # this thread, this block
  OrderJob.perform_async(order.id)           # runs right here
end                                          # back to the global mode
```

`Sidekiq.testing!(:fake)` / `Sidekiq.testing!(:inline) { … }` is the same entry
point under the modern name; it defaults to `:fake` when called with no argument.

Two things to know about the block form:

- The thread-local wins over the global mode, so a block inside a globally-fake
  suite is properly scoped.
- **Nesting block forms raises `Sidekiq::Testing::TestModeAlreadySetError`.**
  `fake! { inline! { … } }` is rejected, matching Sidekiq 8. Set the outer mode
  globally if you need to switch inside it.

Because the mode is a process global plus a thread local, and the fake store is
process-global, a threaded parallel test runner shares both. Wurk's own suite
sidesteps this by forking (`minitest-parallel_fork`); if you parallelize with
threads, use the block form and don't assert on `Sidekiq::Worker.jobs` across
threads.

---

## 2. The fake store

In `:fake` mode each payload is appended to `Sidekiq::Queues`, keyed by queue
name. `enqueued_at` is stamped with the current epoch-ms unless the job is
scheduled — same as the real client. `perform_async` still returns a jid, and
`perform_bulk` still returns the array of jids.

### Per-class helpers

Defined on every class that includes `Sidekiq::Job`:

| Method | Semantics |
|---|---|
| `MyJob.jobs` | Array of payload hashes for this class, across every queue |
| `MyJob.clear` | Remove this class's fake jobs (leaves other classes alone) |
| `MyJob.drain` | Run **and remove** every fake job for this class — including ones enqueued mid-drain. Returns the count processed |
| `MyJob.perform_one` | Run and remove the first fake job for this class. Raises `Sidekiq::EmptyQueueError` if there are none. Returns the job's `perform` value |
| `MyJob.process_job(hash)` | Execute one normalized payload hash through the inline server chain |
| `MyJob.execute_job(instance, args)` | The innermost call — `instance.perform(*args)` |
| `MyJob.queue` | The class's configured queue name |

```ruby
# test/jobs/order_job_test.rb
Sidekiq::Testing.fake! do
  OrderJob.perform_async(1)
  OrderJob.perform_async(2)
end

assert_equal 2, OrderJob.jobs.size
assert_equal [1, 2], OrderJob.jobs.map { |j| j["args"].first }
assert_equal 2, OrderJob.drain
assert_empty OrderJob.jobs
```

A payload is the wire hash, so assert on it with string keys: `"class"`,
`"queue"`, `"args"`, `"jid"`, `"enqueued_at"`, and `"at"` for scheduled jobs.

### Cross-class helpers

`Sidekiq::Job.*` and `Sidekiq::Worker.*` both work — they're the same methods:

| Method | Semantics |
|---|---|
| `Sidekiq::Worker.jobs` | Every fake payload, all classes, flattened |
| `Sidekiq::Worker.clear_all` | Empty the whole store |
| `Sidekiq::Worker.drain_all` | Run everything until the store is empty; returns the count |

### `Sidekiq::Queues` directly

| Method | Semantics |
|---|---|
| `Sidekiq::Queues["default"]` | The **live** array for that queue — `.clear` on it mutates the store |
| `Sidekiq::Queues.jobs` | Every payload, flattened |
| `Sidekiq::Queues.jobs_by_queue` | Live `queue => [jobs]` hash |
| `Sidekiq::Queues.jobs_by_class` | `class name => [jobs]` (alias `jobs_by_worker`) |
| `Sidekiq::Queues.push(queue, klass, job)` | Append a payload by hand |
| `Sidekiq::Queues.delete_for(jid, queue, klass)` | Drop one payload by jid |
| `Sidekiq::Queues.clear_for(queue, klass)` | Drop one class's payloads from one queue |
| `Sidekiq::Queues.clear_all` | Empty the store |

The store is mutex-guarded, and the lock is released before a job runs during a
drain — so a job that enqueues more work doesn't deadlock and its children are
picked up by the same drain.

---

## 3. Minitest

Set the default mode once and clear the store between tests:

```ruby
# test/test_helper.rb
require "wurk"

Sidekiq::Testing.fake!

module ActiveSupport
  class TestCase
    setup { Sidekiq::Worker.clear_all }
  end
end
```

Override per test with the block form:

```ruby
# test/models/order_test.rb
class OrderTest < ActiveSupport::TestCase
  test "enqueues a receipt" do
    order = orders(:one)

    assert_difference -> { ReceiptJob.jobs.size }, 1 do
      order.complete!
    end

    assert_equal [order.id], ReceiptJob.jobs.last["args"]
  end

  test "receipt job charges the card" do
    Sidekiq::Testing.inline! do
      orders(:one).complete!
    end

    assert_predicate orders(:one).reload, :receipted?
  end
end
```

## 4. RSpec

```ruby
# spec/spec_helper.rb
require "wurk"

Sidekiq::Testing.fake!

RSpec.configure do |config|
  config.before { Sidekiq::Worker.clear_all }
end
```

Tag-driven per-example modes:

```ruby
# spec/spec_helper.rb
RSpec.configure do |config|
  config.around(:each, :inline) { |ex| Sidekiq::Testing.inline!(&ex) }
  config.around(:each, :real_redis) { |ex| Sidekiq::Testing.disable!(&ex) }
end
```

```ruby
# spec/models/order_spec.rb
it "charges immediately", :inline do
  expect { order.complete! }.to change { order.reload.receipted? }.to(true)
end
```

`Sidekiq::Testing.inline!(&ex)` works because the block form takes any callable
block — RSpec's example object responds to `call`.

---

## 5. Scheduled jobs

`perform_in` / `perform_at` / `set(wait:)` / `set(wait_until:)` compute an
absolute epoch-seconds `at` and put it on the payload. An interval below
`1_000_000_000` is seconds-from-now; at or above, it's an absolute timestamp. If
the resulting time is **not in the future**, `at` is dropped and the job enqueues
immediately — so `set(wait: 0)` is an ordinary push in every mode.

**In `:fake` mode there is no separate scheduled set.** The payload lands in the
same in-memory queue array as an immediate job, distinguished only by its `"at"`
key (and by *not* having `"enqueued_at"`):

```ruby
Sidekiq::Testing.fake! { ReminderJob.perform_in(1.hour, lead.id) }

job = ReminderJob.jobs.last
assert_in_delta Time.now.to_f + 3600, job["at"], 1.0
assert_nil job["enqueued_at"]
```

Consequences worth internalizing:

- `MyJob.drain`, `perform_one`, and `drain_all` **run scheduled jobs too**, right
  away, ignoring `at`. There is no clock to advance.
- `Sidekiq::ScheduledSet` reads real Redis. In `:fake` mode it is empty no matter
  how many `perform_in` calls you made. To assert on the scheduled ZSET, test
  with the mode disabled (see § 8).
- In `:inline` mode a scheduled job runs **immediately** — the delay is
  discarded, not honored.

---

## 6. What inline execution does and does not do

`:inline` mode (and `drain` / `perform_one`) calls `MyJob.process_job(payload)`,
which instantiates the class, assigns `jid` (and `bid` if the class has one), and
invokes `perform` through `Sidekiq::Testing.server_middleware`.

That is a **separate, empty-by-default chain** — not
`Wurk.configuration.server_middleware`. Add to it explicitly if your test needs
server middleware to run:

```ruby
# test/test_helper.rb
Sidekiq::Testing.server_middleware do |chain|
  chain.add MyApp::TenantMiddleware
end
```

Client middleware, by contrast, **does** run in every mode: the test hook sits
downstream of the client chain, so a middleware that mutates or halts the push
behaves the same fake, inline, or real.

Things that are absent from the inline path because the real
`Wurk::Processor` isn't involved:

- **No retry.** An exception propagates straight out of `perform_async` /
  `drain` to your test. Nothing is written to the retry set, `sidekiq_retry_in` /
  `sidekiq_retries_exhausted` blocks don't fire, and no death handlers run. Test
  retry behavior by calling the hook blocks directly, or against real Redis.
- **No job logging, no stats, no `Sidekiq::WorkSet` entry**, no heartbeat.
- **No interrupt handling.** `Sidekiq::Job::Interrupted` is raised by the
  interrupt-handler server middleware, which isn't in the testing chain — so
  iterable jobs run to completion inline rather than yielding.

---

## 7. Batches, unique jobs, and limiters still use Redis

This is the sharpest edge on the page. The testing modes intercept **the job
push and nothing else.** Features implemented as direct Redis calls are
untouched by them:

| Feature | Behavior under `:fake` / `:inline` |
|---|---|
| `Sidekiq::Batch` | Batch creation, `bid` metadata, callbacks, `linger`, `invalidate_all` all write to real Redis. A Redis connection is required even in `:fake` mode |
| Batch callbacks (`on(:success)`, `on(:complete)`) | **Never fire.** They're driven by the server-side completion path, which inline execution bypasses. Counters do not decrement |
| Batch autoflush buffering | Skipped — the test hook short-circuits ahead of the buffer, so each push is collected/executed individually |
| `Sidekiq::Enterprise.unique!` | The client middleware acquires its lock against real Redis before the test hook runs, so duplicates **are** suppressed in fake mode — and the lock persists past the test unless you flush |
| `Sidekiq::Limiter` | Talks to Redis directly from inside your job body; unaffected by the mode |
| `Sidekiq::Queue`, `RetrySet`, `ScheduledSet`, `DeadSet`, `Stats` | Read real Redis; they never see the fake store |

So: point your test environment at a real (ideally per-worker, isolated) Redis
database even when you run in `:fake` mode, and flush it between tests. Batch and
unique-job assertions belong in the real-Redis tier below.

---

## 8. Testing against real Redis

The fake store is a convenience for "did my model enqueue the right thing".
Anything about *how Wurk handles the job* — retries, the scheduled ZSET, the dead
set, batch completion, uniqueness — is behavior of Redis-backed code, and mocking
Redis to test it only tests the mock. Wurk's own suite forbids mocked Redis in
integration and parity tests for exactly that reason; the same logic applies to
your app.

Run those tests with the mode disabled, against a throwaway Redis database:

```ruby
# test/integration/reminder_scheduling_test.rb
class ReminderSchedulingTest < ActiveSupport::TestCase
  def setup
    Sidekiq.redis { |c| c.call("FLUSHDB") }
  end

  test "parks the job in the scheduled set" do
    Sidekiq::Testing.disable! do
      ReminderJob.perform_in(3600, 42)
    end

    entry = Sidekiq::ScheduledSet.new.first

    assert_equal "ReminderJob", entry.klass
    assert_equal [42], entry.args
    assert_in_delta Time.now.to_f + 3600, entry.score, 5.0
  end
end
```

Guidance that holds up in practice:

- **Never `FLUSHDB` a database you also develop against.** Point the test env at
  a dedicated logical DB (`redis://localhost:6379/15`) and flush that one only.
- Give each parallel test worker its own logical DB (1–15) so concurrent tests
  can't see each other's keys. Wurk's own suite assigns one per forked worker.
- To exercise the *whole* pipeline (fetch, execute, retry) rather than just the
  enqueue, boot workers explicitly — `bundle exec wurk` in a subprocess, or
  `Wurk::Embedded` — since the railtie won't fork under `Rails.env.test?`.

---

## 9. ActiveJob

Jobs enqueued through ActiveJob are pushed as
`Sidekiq::ActiveJob::Wrapper`, with the serialized ActiveJob payload as the
single argument. That's the wire shape Sidekiq emits, and it's what the fake
store records:

```ruby
Sidekiq::Testing.fake! { MyMailer.welcome(user).deliver_later }

assert_equal 1, Sidekiq::ActiveJob::Wrapper.jobs.size
```

`MyMailerJob.jobs` will be empty — the payload's `"class"` is the wrapper, not
your job class. If you'd rather assert in ActiveJob's own vocabulary
(`assert_enqueued_with`, `perform_enqueued_jobs`), set
`ActiveJob::Base.queue_adapter = :test` in the test environment and leave Wurk's
modes out of it. `:inline` mode does run wrapped ActiveJob payloads correctly —
the wrapper resolves and calls `ActiveJob::Base.execute`.

---

## 10. Migrating an existing Sidekiq suite

The whole `Sidekiq::Testing` / `Sidekiq::Queues` / `Sidekiq::Job` test surface is
implemented, under the same names, with the same semantics. In practice a suite
moves over untouched. Two things to check:

**1. `require "sidekiq/testing"` no longer implies `fake!`.** The path still
resolves (it loads Wurk), but Wurk's default mode is `:disable`. Under Sidekiq,
requiring that file switched you into fake mode as a side effect; here a suite
that relied on it will start writing to real Redis and every `MyJob.jobs`
assertion will come back empty. Add one explicit line to your test helper:

```ruby
# test/test_helper.rb
Sidekiq::Testing.fake!
```

There is no deprecation warning on the require — the file is a plain
`require "wurk"`.

**2. `Sidekiq::Testing` is a module, not a class.** Wurk implements it as a
module with singleton methods. Every documented call (`fake!`, `inline!`,
`disable!`, the predicates, `server_middleware`, `__set_test_mode`) is identical;
only `Sidekiq::Testing.is_a?(Class)` and subclassing it would differ, and neither
appears in real suites.

There is no `Sidekiq::TestingClient` monkey-patch of `atomic_push` — inline
dispatch is handled inside `raw_push` instead. Behavior is the same; only reach
for this if you patched Sidekiq's internals yourself.

---

## Related

- [Migrating from Sidekiq](migrate-from-sidekiq.md) — the full swap checklist.
- [ActiveJob](active-job.md) — adapter setup and wire format.
- [Running Wurk](running.md) — how workers actually boot outside the test env.
