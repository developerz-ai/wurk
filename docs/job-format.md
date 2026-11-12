# Job format

How to put a job in Redis from any language, so a Wurk (or stock Sidekiq)
worker runs it. This is the Sidekiq wire format; Wurk does not extend it. The
authoritative source is [`docs/target/sidekiq-free.md`](target/sidekiq-free.md)
§1 (keys) and §2 (payload); this page is the producer's view of it.

If you can make an HTTP call instead, `POST /v1/jobs` ([`api-http.md`](api-http.md))
builds all of this for you. Write to Redis directly only when that is not an
option.

`test/parity/job_format_test.rb` pushes hand-built payloads with raw Redis
commands, runs them through a real processor and checks the required fields,
the scheduled promotion path and the failure shape below.

## The payload

One JSON object, string keys, UTF-8. Stored as the exact bytes you send.

### Required

| Key | Type | Value |
|---|---|---|
| `class` | string | The worker class name, e.g. `"HardWorker"` or `"Billing::Charge"`. |
| `args` | array | Arguments to `perform`, JSON-native values only: numbers, strings, `true`/`false`/`null`, arrays, objects with string keys. |
| `queue` | string | Non-empty queue name, without the `queue:` prefix. |
| `jid` | string | Unique job id. Sidekiq uses 24 lowercase hex characters (12 random bytes). |
| `created_at` | integer | Epoch **milliseconds** when the job was created. |
| `retry` | boolean or integer | `true` (25 attempts), `false` (none), or an attempt count. |

### Set on push

| Key | Type | Value |
|---|---|---|
| `enqueued_at` | integer | Epoch **milliseconds** when the job was pushed onto its queue. Set it on an immediate push; leave it out of a scheduled one (the scheduler stamps it on promotion). |

### Optional

| Key | Type | Value |
|---|---|---|
| `retry_queue` | string | Queue retries go to; defaults to `queue`. |
| `retry_for` | integer | Seconds to keep retrying, counted from the first failure. Replaces the attempt count. |
| `backtrace` | boolean or integer | Store the error backtrace on failure: `true` for all lines, N for the first N. |
| `dead` | boolean | `false` skips the dead set when retries run out. |
| `tags` | array of strings | Labels shown in the dashboard. |
| `log_level` | string | Logger level for this job. |
| `wrapped` | string | The ActiveJob class when `class` is the ActiveJob wrapper. |

Integers are kept exact. A value past 2^53 (a 64-bit id) arrives in `perform`
as the same integer, provided your own JSON encoder writes it as an integer
literal and not as a float.

### Written by the worker, not by you

`retry_count`, `failed_at`, `retried_at`, `error_class`, `error_message`,
`error_backtrace`, `discarded_at`. On a first failure the job is stored in
`retry` with `retry_count: 0`, the exception's class and message, and
`failed_at` in epoch milliseconds. Every field you wrote is kept unchanged.

### Timestamps

Sidekiq 8 writes `created_at`, `enqueued_at`, `failed_at` and `retried_at` as
integer epoch milliseconds. Readers also accept the older float epoch
**seconds**, so jobs from an older producer keep running. Sorted-set scores
and `at` are always float epoch seconds.

## Run now

Two commands, ideally in one `MULTI`:

```
SADD queues <queue>
LPUSH queue:<queue> <payload JSON>
```

`SADD` is what makes the queue show up in the dashboard and `Queue.all`;
workers fetch from the list whether or not it is there.

## Run later

```
ZADD schedule <epoch seconds, float> <payload JSON>
```

Leave `enqueued_at` and `at` out of the stored payload. When the score is
due, the scheduler moves the member to `queue:<queue>`, adds the queue to
`queues` and sets `enqueued_at`.

## Example

```json
{
  "class": "HardWorker",
  "args": [42, "two", {"k": [1, 2]}],
  "queue": "default",
  "jid": "b4a577edbccf1d805744efa9",
  "created_at": 1786000000123,
  "enqueued_at": 1786000000123,
  "retry": true
}
```

```python
import json, os, time, redis

r = redis.Redis.from_url(os.environ["REDIS_URL"])
now_ms = int(time.time() * 1000)
job = {"class": "HardWorker", "args": [42, "two"], "queue": "default",
       "jid": os.urandom(12).hex(), "created_at": now_ms,
       "enqueued_at": now_ms, "retry": True}
with r.pipeline(transaction=True) as p:
    p.sadd("queues", "default")
    p.lpush("queue:default", json.dumps(job))
    p.execute()
```

## What a direct write skips

`Wurk::Client` runs the client middleware chain on every push. A payload
written straight to Redis bypasses it, so these need the HTTP API or a Ruby
producer: unique locks (`unique_for`), batch membership (`bid`), encryption
(`encrypt`), `expires_in` and `collapse`.
