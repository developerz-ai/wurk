# wurk-client

A thin, zero-dependency reference client for the [Wurk](https://github.com/developerz-ai/wurk)
HTTP API (`/v1`) — see [`docs/api-http.md`](../../docs/api-http.md) for the
full route reference this wraps.

Not yet published to PyPI — the wire contract this client speaks to is part
of an in-progress PR; install from the repo until it's declared frozen
(`docs/plans/2026/08/07/101-beyond-sidekiq/07-http-producer-api.md`, step 8):

```bash
pip install ./clients/python
# or, for local development on the client itself:
pip install -e ./clients/python
```

## Usage

```python
from wurk_client import Client, WurkAPIError, RateLimitedError

wurk = Client("https://jobs.example.com/wurk/api", token="...")

# Enqueue one job — same Sidekiq job hash Wurk's Ruby producers push;
# nothing is reshaped at the boundary.
jid = wurk.enqueue("HardWorker", args=[1, "two"], queue="default", retry=5)

# Enqueue many at once (the Lua bulk path)
jids = wurk.bulk("HardWorker", [[1], [2], [3]], queue="default")

# Poll a tracked job's status/progress/result (class must set track: True)
record = wurk.status(jid)

# Observe
wurk.queues()             # every queue's name/size/latency/paused
wurk.queue("default")     # one queue's gauges + a page of waiting jobs
wurk.stats()              # processed/failed/enqueued/... counters

# Pull a not-yet-run job back out of schedule/retry (requires an admin token)
wurk.cancel(jid)
```

### Idempotent enqueue

A dropped connection means "did this enqueue or not?" — send an
`Idempotency-Key` and a resend replays the first response instead of
enqueuing twice:

```python
wurk.enqueue("ChargeCard", args=[order_id], idempotency_key=f"charge-{order_id}")
```

### Errors

Every non-2xx response raises `WurkAPIError`, carrying the same fields as the
server's [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem document:

```python
try:
    wurk.status(jid)
except WurkAPIError as e:
    print(e.status, e.type, e.detail)   # e.g. 404 "job_not_found" "..."
```

`e.type` is the stable slug to branch on (see the table in
`docs/api-http.md#errors`) — never `e.detail`, which is prose for a human. A
`429` raises the narrower `RateLimitedError`, which adds `.retry_after`
(seconds, matching the `Retry-After` header).

## What this is not

Thin by design, matching the plan doc's brief: enqueue, bulk, status, queues
— and a little more (`cancel`, `pause_queue`/`unpause_queue`, `stats`) since
they're nearly free once the transport exists. No retries, no connection
pooling, no async, no framework integration. Wrap this client, or reach for
`requests`/`httpx` yourself, if you need any of that — keeping this package
dependency-free means it never fights a host application's own pin.

## Development

```bash
cd clients/python
python -m unittest discover -s tests
```

Tests mock at the `urllib.request.urlopen` boundary, so they exercise the
client's real request-building (headers, JSON body, query string) and
response-parsing code — not a stub standing in for the client itself.
