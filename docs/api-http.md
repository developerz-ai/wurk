# Wurk HTTP API (`/v1`)

A machine-facing, polyglot HTTP surface over the same Redis a Wurk swarm reads
and writes. A Python, Go, Node, or any other non-Ruby service can enqueue a
job here and a Ruby (or stock Sidekiq) worker runs it — same Redis keys, same
job JSON, nothing invented at the boundary.

**Off unless a token is configured.** With no `config.api_token` registered,
none of this exists: no route is mounted, no port opens, nothing changes on
the hot path. This is the additive invariant the whole surface is built on —
see [`docs/plans/2026/08/07/101-beyond-sidekiq/07-http-producer-api.md`](plans/2026/08/07/101-beyond-sidekiq/07-http-producer-api.md)
for the design rationale.

## Contents

- [Enabling it](#enabling-it)
- [Mounting](#mounting) — three ways, one implementation
- [Authentication & scopes](#authentication--scopes)
- [Versioning](#versioning)
- [Errors](#errors)
- [Idempotency](#idempotency)
- [Read-only mode](#read-only-mode)
- [Rate limiting](#rate-limiting)
- [Routes](#routes) — produce, observe (queues & sets), observe (swarm)
- [Reference clients](#reference-clients)

## Enabling it

```ruby
# config/initializers/wurk.rb, or any app boot code that runs in every
# process that should serve the API
Wurk.configuration.api_token ENV.fetch('WURK_API_TOKEN'), scopes: %i[enqueue read]
```

Register the token **unconditionally** — not inside `configure_server` /
`configure_client`. Neither block runs in every process type; in particular a
Puma-cluster web process never enters "server mode", so a token set only in
`configure_server` would be absent from exactly the process serving the
engine-nested mount (mode 1 below). Registering the first token is what
brings the API into existence at all; call it again to replace a token's
scopes.

`scopes:` is any non-empty subset of `%i[enqueue read admin]` — see
[Authentication & scopes](#authentication--scopes).

## Mounting

`Wurk::API` is a plain Rack app (`lib/wurk/api/app.rb`) with no reference to
Rails. One implementation serves all three mounts; nothing in it hardcodes a
prefix — every URL it emits (including the discovery document's `url` field)
is derived from `SCRIPT_NAME`.

### 1. Inside the engine (default)

Any app that already mounts the engine gets the API for free at
`<mount>/api/v1`, once a token exists:

```ruby
# config/routes.rb
mount Wurk::Engine => '/wurk'   # dashboard at /wurk, API at /wurk/api/v1
```

With no token registered, the route does not exist — Rails falls through to
whatever `/wurk/api/...` would have answered before (a 404, same as any other
unmounted path), never a bearer challenge advertising a surface that isn't
there.

The dashboard's own JSON API lives under the same `/api` prefix
(`config/routes.rb`'s `scope :api`) and is declared first, so
`/wurk/api/queues` (dashboard, SPA-shaped, session-authenticated) and
`/wurk/api/v1/queues` (machine plane, bearer-authenticated) coexist without
conflict — the machine plane only claims paths under `/v1`.

Read-only mode is inherited here: `WURK_WEB_READ_ONLY=1` (or
`Wurk::Web.config.read_only`) freezes the dashboard *and* this mount's writes
— see [Read-only mode](#read-only-mode).

### 2. Mounted separately

Useful to put the machine API on its own path, subdomain, or middleware
stack — e.g. the dashboard behind a login on the app domain, the API on an
internal-only route with its own network policy:

```ruby
mount Wurk::API => '/wurk-api'   # API at /wurk-api/v1, dashboard untouched
```

Rails matches a mounted app by string prefix, so if an engine is also mounted
at a prefix your separate mount extends (`mount Wurk::Engine => '/wurk'` and
`mount Wurk::API => '/wurk-api'`), **declare the more specific route first**.
Declared after, the engine's own catch-all would answer `/wurk-api/...`
requests instead (for `html`-format requests only — a JSON request still
cascades past it via `X-Cascade`, but a browser hitting the API's root would
otherwise see the dashboard shell).

This mount has no engine `Authorization` layer in front of it, so read-only
mode is *not* inherited from `WURK_WEB_READ_ONLY`. Opt in explicitly with
`config.api_read_only = true` or `WURK_API_READ_ONLY=1` if you want it.

### 3. Standalone, no Rails

`CLAUDE.md`: standalone mode must run without loading the engine.
`Wurk::API` is plain Rack under `lib/`, so it runs on its own:

```bash
bundle exec wurk api --port 7433 -r ./config/environment.rb
# or, in any config.ru:
run Wurk::API
```

```
$ bundle exec wurk api --help
Usage: wurk api [options]
    -b, --bind ADDRESS               Address to bind (default 0.0.0.0)
    -p, --port PORT                  Listen on PORT
    -s, --server NAME                Rack handler to serve with (default: the first installed)
    -r, --require [PATH|DIR]         Location of Rails app or .rb file to require
    -e, --environment ENV            Application environment
    -C, --config PATH                path to YAML config file
```

`wurk api` starts **only** the HTTP surface — no fetcher, no heartbeat, no
job ever runs in this process. It binds `0.0.0.0` by default (the point of
the machine API is for another service to reach it — it's bearer-gated and
answers 404 to everything until a token exists); narrow it with `--bind
127.0.0.1` behind your own proxy if you'd rather. The web server itself
(`Rack::Handler::*`) is not a Wurk dependency, same as it isn't for a Rails
app — install `puma`, `webrick`, or whichever handler you prefer and `wurk
api` resolves it at boot, or name one explicitly with `--server`.

With no token registered, `wurk api` refuses to boot rather than binding a
port that would 404 every request:

```
No API token is registered, so every request would answer 404.
Register one where the app loaded by -r configures wurk:

    Wurk.configuration.api_token ENV.fetch('WURK_API_TOKEN'), scopes: %i[enqueue read]
```

## Authentication & scopes

Every request needs `Authorization: Bearer <token>`. Compared in constant
time against every registered token — no early exit on a match — so timing
can't leak which token, or how much of one, a caller guessed right.

Three scopes, one implication:

| Scope | Grants |
|---|---|
| `enqueue` | `POST /jobs`, `POST /jobs/bulk` |
| `read` | every `GET`, plus `GET /jobs/:jid` |
| `admin` | everything — implies `enqueue` and `read`, plus the destructive routes (`DELETE /jobs/:jid`, queue pause/unpause, process quiet/stop) |

```ruby
Wurk.configuration.api_token ENV.fetch('WURK_PRODUCER_TOKEN'), scopes: %i[enqueue read]
Wurk.configuration.api_token ENV.fetch('WURK_OPERATOR_TOKEN'), scopes: %i[admin]
```

- **No token presented** → `401`, `WWW-Authenticate: Bearer realm="wurk"`.
- **Unrecognized token** → `401`, `WWW-Authenticate: Bearer realm="wurk", error="invalid_token"`.
- **Valid token, wrong scope** → `403` (`insufficient_scope`), `WWW-Authenticate` names the scope required — never a `404` hiding the route, since the caller already proved a valid credential and only needs to know what to ask their operator for.
- **No token configured on the server at all** → the whole surface is `404` — see [Enabling it](#enabling-it).

`class` in an enqueued job selects which of the host's code runs, so a
polyglot producer that can name *any* class is remote code selection.
`config.api_enqueue_classes` is a class allow-list layered on top of scopes:

```ruby
# Only these two classes may be enqueued over HTTP, by any token including admin
Wurk.configuration.api_enqueue_classes = %w[Billing::Charge ReportJob]

# Turn the check off entirely (an internal relay that legitimately enqueues anything)
Wurk.configuration.api_enqueue_classes = :any
```

Unset (the default), only an `admin` token may enqueue at all — an
`enqueue`-scoped token enqueues nothing until you either grant it `admin` or
write a list.

## Versioning

Everything lives under `/v1`. The discovery document is the first thing a
client should call to confirm which mount and contract it's talking to:

```
GET /v1
```
```json
{
  "api_version": "v1",
  "wurk_version": "8.4.0",
  "url": "/wurk/api/v1",
  "read_only": false,
  "rate_limit": { "limit": 600, "interval_seconds": 60 }
}
```

`url` is built from the actual mount prefix the request arrived through —
never hardcoded — so a client can trust it as the base for every subsequent
request. `read_only` and `rate_limit` are reported here because both are
things a producer would otherwise only discover by having a write refused;
reading them at startup means a misconfigured deployment fails in the
client's own logs instead of halfway through a batch.

An unrecognized version prefix (`/v2/...`) is a `404`
(`unsupported_api_version`), not a `400` — the address doesn't exist, the
client's request was otherwise well-formed. All three mounts answer it the
same way: the engine-nested mount claims every version-shaped path, not only
the one it serves, so a wrong version never degrades into the host app's own
route miss.

## Errors

Every error is an [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem
document, `Content-Type: application/problem+json`:

```json
{
  "type": "job_not_found",
  "title": "Job Not Found",
  "status": 404,
  "detail": "No scheduled or retrying job has jid abc123.",
  "instance": "/v1/jobs/abc123",
  "jid": "abc123"
}
```

`type` is a **bare, stable slug** — not a URI. It's the field a client
branches on; renaming one is a breaking change, adding one is not.

| `type` | HTTP status | Meaning |
|---|---|---|
| `not_found` | 404 | No route matches this path. |
| `method_not_allowed` | 405 | Route exists, wrong verb — `Allow` header lists what does. |
| `unsupported_api_version` | 404 | Not `/v1`. |
| `unauthorized` | 401 | Missing or invalid bearer token. |
| `insufficient_scope` | 403 | Valid token, missing scope. |
| `invalid_request` | 400 | Malformed body, bad query param, unknown top-level job key. |
| `payload_too_large` | 413 | Body, `args`, or one bulk job's `args` exceeded its configured cap (`max_bytes` extension member). |
| `class_not_allowed` | 403 | `class` is not on `config.api_enqueue_classes`. |
| `job_not_found` | 404 | No scheduled/retrying job, or no tracked status, for this jid. |
| `batch_not_found` | 404 | No batch with this bid. |
| `flow_not_found` | 404 | No flow with this fid. |
| `process_not_found` | 404 | No live process with this identity. |
| `process_not_signalable` | 409 | Process is embedded in its host app; signalling it would signal the host. |
| `idempotency_key_reused` | 409 | Same `Idempotency-Key`, different request body — rotate the key. |
| `request_in_progress` | 409 | Another request under this `Idempotency-Key` hasn't answered yet — retry shortly (`Retry-After: 1`). |
| `read_only` | 403 | This deployment (or mount) answers reads only. |
| `rate_limited` | 429 | Per-token ceiling exceeded — `Retry-After` header and `retry_after` body field agree. |
| `internal_error` | 500 | Unexpected server error; details are in the server log, never the response. |

## Idempotency

A producer whose connection drops mid-`POST /jobs` can't tell a lost request
from a lost response, so its only safe move is to resend — which, without
help, enqueues the job twice. Send an `Idempotency-Key` and a resend replays
the *first* response verbatim instead:

```
POST /v1/jobs
Idempotency-Key: order-42-charge
```

- The first request with a key runs normally; its response (status + body) is
  recorded for `config.api_idempotency_ttl` seconds (default 3600).
- A repeat with the **same** key and **same** body gets the recorded response
  back, with `Idempotency-Replayed: true`, and nothing is enqueued twice.
- A repeat with the same key and a **different** body is a client bug:
  `409 idempotency_key_reused`. Fix the request or use a new key.
- A repeat that arrives while the first request is still in flight gets
  `409 request_in_progress` with `Retry-After: 1`.
- Only a *successful* (2xx) response is recorded. A rejected request (`400`,
  `413`, ...) releases the key, so the corrected request can reuse it.

No header, no behavior change and no extra round trip — this is entirely
opt-in.

The key is scoped to the credential and the route: two different tokens
sending the same key string don't collide, and the same key sent to `/jobs`
and `/jobs/bulk` addresses two independent claims.

## Read-only mode

One rule, same word, same meaning as the dashboard's:
`Wurk::Web.config.read_only` / `WURK_WEB_READ_ONLY=1` freezes every
non-`GET`/`HEAD`/`OPTIONS` request — enqueue included, not only the
`admin`-scoped destructive routes. A deployment an operator can't retry a job
on shouldn't let a stranger start a thousand new ones on it.

| Mount | Inherits `WURK_WEB_READ_ONLY`? | Its own switch |
|---|---|---|
| 1. Engine-nested | Yes, automatically | `config.api_read_only = false` overrides it back to live |
| 2. Mounted separately | No — different deployment, nothing to inherit from | `config.api_read_only = true` / `WURK_API_READ_ONLY=1` |
| 3. Standalone (`wurk api`) | No | same as mode 2 |

A refused write is `403 read_only` — distinct from `insufficient_scope`
because the fix is different: nothing the client can send changes the answer,
where a scope error is fixable by asking for a wider token.

## Rate limiting

Off by default. Set a per-token ceiling with:

```ruby
Wurk.configuration.api_rate_limit = 600
Wurk.configuration.api_rate_limit_interval = :minute   # or :second/:hour/:day, or raw seconds
```

Enforced by the same `Wurk::Limiter` sliding window jobs use — it shows up on
`GET /v1/limiters` and the dashboard's Limiters page beside every other one,
and its verdict is shared across every process in the fleet off one Redis
clock. Over the ceiling: `429 rate_limited`, `Retry-After` header (whole
seconds, never `0`), and the same number echoed in the body as `retry_after`.

## Routes

Body is always the literal Sidekiq job hash — nothing invented, nothing
reshaped. An HTTP-enqueued job is byte-identical to one pushed by
`perform_async` in this process and runs unmodified on stock Sidekiq.

### Produce

| Route | Scope | Notes |
|---|---|---|
| `POST /jobs` | `enqueue` | One job. `201` + `{"jid": "..."}`, or `200` + `{"jid": null}` if server-side middleware (`collapse:`, `unique_for:`) dropped the push — that's the producer's own policy working, not a failure. |
| `POST /jobs/bulk` | `enqueue` | Many, via the Lua bulk path. `{"class": ..., "args": [[...], [...]], "batch_size": 1000, "spread_interval": 5}`. `201`/`200` + `{"jids": [...]}`, index-aligned with `args`; `null` entries mark drops. |
| `GET /jobs/:jid` | `read` | State, progress, result, error — from `Wurk::Status`. Only answers for a class with `track: true`; an untracked, unknown, or TTL-expired jid all read the same `404 job_not_found`, because Redis holds nothing that tells them apart. |
| `DELETE /jobs/:jid` | `admin` | Removes a not-yet-run job from `schedule` or `retry` by jid. **Not** a running-job cancel — a job already handed to a processor keeps running, and one that already died stays in `dead`. |

Job body, all keys optional except `class`:

```json
{
  "class": "HardWorker",
  "args": [1, "two"],
  "queue": "default",
  "at": 1786000000,
  "retry": 5,
  "tags": ["billing"],
  "track": true,
  "timeout": 30,
  "deadline": 1786000600,
  "unique_for": 300,
  "collapse": "user-42-digest"
}
```

Allowed top-level keys: `class args queue at retry jid backtrace tags dead
retry_for retry_queue expires_in track timeout deadline encrypt unique_for
unique_until collapse log_level locale wrapped` (plus `batch_size` and
`spread_interval` for `/jobs/bulk`). An unknown key is `400 invalid_request`
rather than silently dropped — a typo'd `deadlin:` would otherwise run
unbounded with the producer none the wiser. Fields the server derives or
stamps itself (`created_at`, `enqueued_at`, `bid`, `expiry`, ...) are not
accepted from the client.

Caps (all configurable): request body (`config.api_max_body_bytes`, default 1
MiB), one job's `args` (`config.api_max_args_bytes`, default 64 KiB) —
checked per job for `/jobs/bulk`, so one oversized entry in a large batch
doesn't cost reading the whole body to find.

### Observe — queues & sets

Every route reads through the same canonical inspector the dashboard uses
(`Wurk::Stats`, `Queue`, `RetrySet`, `ScheduledSet`, `DeadSet`,
`Batch::Status`) — the API and the dashboard can never disagree about how
deep a queue is.

| Route | Scope | Notes |
|---|---|---|
| `GET /stats` | `read` | Processed/failed/expired/enqueued counters, queue summaries. |
| `GET /queues` | `read` | Every queue: name, size, latency, paused. Size-descending. |
| `GET /queues/:name` | `read` | Gauges + a page of waiting jobs. No `404` for an unused name — a queue is a Redis LIST that exists only while it has members, so "never enqueued" and "just drained" are the same state. |
| `POST /queues/:name/pause` | `admin` | Stops the fleet fetching from this queue. |
| `POST /queues/:name/unpause` | `admin` | |
| `GET /retries` | `read` | Paged `retry` set. |
| `GET /scheduled` | `read` | Paged `schedule` set. |
| `GET /dead` | `read` | Paged `dead` set. |
| `GET /batches/:bid` | `read` | Batch status/counters. `404 batch_not_found` if never created or expired. |
| `GET /flows/:fid` | `read` | A flow's state, counters and whole node graph. `404 flow_not_found` if never created or expired. |

There is no `GET /flows` and no way to abandon one over this API. A producer
holds the fid of the flow it created, which is the only flow it has a question
about; browsing every flow in the deployment, and deciding one is stuck enough
to kill, are things an operator does with the graph on screen — the dashboard's
Flows pages.

Paged routes take `?page=` (0-based) and `?count=` (default 25, max 200);
out-of-range values are clamped, not refused, and the effective values are
echoed back so the clamp is visible.

### Observe — swarm & topology

Read-only against structures that already exist — no new Redis key, no new
heartbeat field, and watching the swarm through these routes costs it nothing
(`Wurk::ProcessSet.new(false)`, the same non-mutating read the dashboard's
live poll uses). A monitoring client hitting `GET /swarm` every few seconds
adds zero write traffic.

| Route | Scope | Notes |
|---|---|---|
| `GET /swarm` | `read` | Cluster roll-up: process/quiet/stale counts, total concurrency & utilization, queues & versions in play, leader identity, per-host breakdown, observed slot table, oldest beat age. |
| `GET /processes` | `read` | Paged, one row per live process: identity, hostname, pid, tag, version, concurrency, queues, busy, RSS, `beat_age_seconds`, `stale`, `quiet`. |
| `GET /processes/:identity` | `read` | One process's row plus its in-flight work. `404 process_not_found` if it's exited or its heartbeat lapsed. |
| `POST /processes/:identity/quiet` | `admin` | SIGTSTP-equivalent — stop fetching, finish in-flight. `identity=all` broadcasts. Asynchronous: `200` means queued, applied on the target's next beat. |
| `POST /processes/:identity/stop` | `admin` | SIGTERM-equivalent — graceful shutdown. Same broadcast/async rules. |
| `GET /busy` | `read` | Paged, every in-flight job cluster-wide. |
| `GET /health` | `read` | Redis reachability + live/stale/quiet process counts — the same question `lib/wurk/health.rb`'s TCP probe answers, re-derived for a process that has no probe of its own. `503` when Redis is unreachable or no process is live. **Not** a substitute for `config.health_check(port:)` — a Kubernetes probe must never carry a bearer token. |
| `GET /limiters` | `read` | Paged; supports `?filter=` (substring). |
| `GET /cron` | `read` | Paged registered cron loops with `next_fire_at`. |

Heartbeat staleness: a process that died between beats is still in
`processes` until its TTL lapses. Every row and the roll-up both carry
`beat_age_seconds` and a derived `stale` boolean (age past three missed beats,
`30s` at the default heartbeat cadence) so a client never has to compare its
own clock against a `beat` timestamp.

Signalling an **embedded** process (one running inside the host web process,
not a forked swarm child) is refused with `409 process_not_signalable` — a
TSTP or TERM aimed at it would hit the web server around it, not just the job
loop.

## Reference clients

**Python** — [`clients/python/`](../clients/python/), zero third-party
dependencies (`urllib.request` under the hood):

```python
from wurk_client import Client

wurk = Client("https://jobs.example.com/wurk/api", token=API_TOKEN)
jid = wurk.enqueue("HardWorker", args=[1, "two"], queue="default")
wurk.status(jid)      # {"jid": ..., "state": "running", ...} — track: True jobs only
wurk.queues()          # [{"name": "default", "size": 3, ...}, ...]
```

See [`clients/python/README.md`](../clients/python/README.md) for the full
surface (`enqueue`, `bulk`, `status`, `cancel`, `queues`, `queue`,
`pause_queue`/`unpause_queue`, `stats`) and error handling
(`WurkAPIError`/`RateLimitedError`).

Thin on purpose: no retries, no connection pooling, no framework
integration — wrap it, or reach for `requests`/`httpx` yourself, for
anything beyond a straight `/v1` call. Not yet published to PyPI; install
from the repo (`pip install ./clients/python`) until the surface above is
declared frozen.
