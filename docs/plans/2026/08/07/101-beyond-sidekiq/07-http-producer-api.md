# 07 — HTTP API: enqueue, status, swarm

> Part of [`overview.md`](overview.md). Depends on: 06 (`GET /jobs/:jid` needs `Wurk::Status`). Enqueue + swarm endpoints can land before 06; gate the job-status route on it.
>
> **Additive invariant:** the API is **off unless a token is configured**. No token → no routes mounted, no behavior change, nothing new on the hot path. It is a producer + observer of existing Redis structures; it does not alter how jobs are stored or run.

## Why

Sidekiq has no supported remote enqueue path. Faktory is the only mainstream polyglot option and needs its own server process. Wurk can serve it from the engine the app already mounts — a Python or Go service enqueues into the same Redis, and a Ruby swarm runs it.

## What exists (and why it isn't this)

`config/routes.rb` already has a JSON API — but it is a **dashboard** API: SPA-shaped payloads, same-origin CSRF (`app/controllers/concerns/wurk/same_origin_guard.rb`), session / `Wurk::Web.use` auth, unversioned, **read + mutate only, no create**. Its shape is free to change when the SPA changes. A machine-facing API needs the opposite guarantee. Build a separate plane; reuse the serializers (`app/controllers/wurk/api/serializers.rb`) and pagination (`api/pagination.rb`), not the controller.

## Surface (`/api/v1`)

### Produce
| Route | Notes |
|---|---|
| `POST /jobs` | one job |
| `POST /jobs/bulk` | many — maps to the existing Lua bulk path (`client.rb:84`, `:300`) |
| `GET /jobs/:jid` | state, progress, result, error — **needs slice 06** |
| `DELETE /jobs/:jid` | remove from schedule/retry sets by jid (not a running-job cancel — that's a separate deferred feature) |

Body is the Sidekiq job hash, nothing invented:
```json
{ "class": "HardWorker", "args": [1, "two"], "queue": "default", "at": 1786000000, "retry": 5 }
```

### Observe — queues & sets
`GET /queues` · `GET /queues/:name` · `POST /queues/:name/pause` · `POST /queues/:name/unpause` · `GET /stats` · `GET /retries` · `GET /scheduled` · `GET /dead` · `GET /batches/:bid`.
All read through the canonical inspectors (`Wurk::Stats`, `Queue`, `RetrySet`, `ScheduledSet`, `DeadSet`, `BatchSet`) — same objects the dashboard uses, so the two can never disagree.

### Observe — swarm / topology
The "how is the swarm actually working" surface. Everything below already exists in Redis or in-process; this exposes it over HTTP.

| Route | Source | Returns |
|---|---|---|
| `GET /swarm` | `Wurk::ProcessSet` + `lib/wurk/topology.rb` | cluster roll-up: process count, child slots per host, total concurrency, queues served, leader identity (`lib/wurk/leader.rb`), rolling-restart state (`swarm/restart.rb`), quiet/stopping flags |
| `GET /processes` | `Wurk::ProcessSet` | per-process: identity, hostname, pid, tag, concurrency, queues, busy count, RSS, `beat` age, quiet flag, version |
| `GET /processes/:identity` | ditto | one process + its in-flight work |
| `POST /processes/:identity/quiet` · `/stop` | same signals as the Busy page (`api_controller#quiet_process`, `#stop_process`) | TSTP / TERM; `all` targets every process |
| `GET /busy` | `Wurk::WorkSet` | currently-executing jobs cluster-wide |
| `GET /health` | `lib/wurk/health.rb` | the K8s liveness/readiness view, as JSON |
| `GET /limiters` · `GET /cron` | `Wurk::Limiter`, `Wurk::Cron::LoopSet` | limiter state, cron entries + next-fire |

Heartbeat staleness matters here: a process that died between beats is still in `processes` until its TTL lapses. Return `beat_age_seconds` and a derived `stale` boolean rather than making every client re-derive it.

## Mounting

Three ways, one implementation. `Wurk::API` is a Rack app; the engine just mounts it.

**1. Inside the engine (default).** Already-mounted apps get it for free at `<mount>/api/v1` once a token is set:
```ruby
# config/routes.rb
mount Wurk::Engine => "/wurk"        # API at /wurk/api/v1
```

**2. Mounted separately.** Useful to put the machine API on a different path, host, or middleware stack than the dashboard — e.g. dashboard behind Devise on the app domain, API on an internal-only route:
```ruby
mount Wurk::API => "/wurk-api"       # API at /wurk-api/v1, dashboard untouched
```

**3. Standalone, no Rails.** `CLAUDE.md`: standalone mode must run without the engine. `Wurk::API` is plain Rack under `lib/`, so:
```bash
bundle exec wurk api --port 7433     # or: run Wurk::API in any config.ru
```

Mount-agnostic like the SPA (`dashboard_controller.rb:41-51`): never hardcode `/wurk` in a URL the API emits — derive from `SCRIPT_NAME`.

## Files to change

- new `lib/wurk/api/` — `app.rb` (Rack router), `auth.rb`, `jobs.rb`, `queues.rb`, `swarm.rb`, `serializers.rb`.
- `lib/wurk/engine.rb` + `config/routes.rb` — conditional mount when a token is configured.
- `lib/wurk/cli.rb` — `wurk api` subcommand.
- `lib/wurk/configuration.rb` — tokens, scopes, enable flag, payload caps, throttle.
- new `clients/python/` (or a sibling repo) — one reference client.
- `docs/api-http.md` — new; slice 12 wires it into README/site/wiki/`llms.txt`.

## Steps

1. **Auth first, before any route works.** Bearer tokens, scoped `enqueue` / `read` / `admin`. Compare with a constant-time check. No token configured → the app isn't mounted at all (not "mounted and 401" — don't advertise a surface that shouldn't exist). Never reuse the dashboard's session/CSRF path; `same_origin_guard` is meaningless for a machine client and would only weaken it.
2. **Byte-identical enqueue.** Route straight through `Wurk::Client#push` / `#push_bulk` (`client.rb:71,84`) — do **not** hand-build a payload. This is the pillar-1 test: an HTTP-enqueued job must be indistinguishable from a Ruby-enqueued one, and runnable by stock Sidekiq.
3. **Validate at the boundary.** Class name is a string from the network: enforce a strict format, cap `args` size, cap total body size, reject unknown top-level keys. A `strict_classes:` mode (allow-list of enqueueable classes) defaults **on** for `enqueue`-scoped tokens — a polyglot producer that can name any constant is remote code selection.
4. Idempotency: `Idempotency-Key` header → server-side dedupe; composes with slice 09 once that lands. Until then, a short-TTL seen-key set.
5. Errors as RFC-9457-ish JSON problem objects, stable machine-readable `type` strings. Versioned path (`/v1`) means the shape is a contract — write it down in `docs/api-http.md` at the same time as the code.
6. Rate-limit per token; return `Retry-After`. Reuse `Wurk::Limiter` rather than a second limiter implementation.
7. Swarm endpoints read `ProcessSet`/`WorkSet`/`Health` only — no new heartbeat writes, no new Redis keys, no extra beat traffic.
8. One reference client (Python or TS), thin: enqueue, bulk, status, queues. Publish only after the surface is frozen.

## Non-goals

- **No consumer protocol.** Faktory-style fetch/ack over HTTP means owning lease semantics, heartbeats, and reclaim for clients Wurk can't test — it puts the reliability guarantee in third-party hands. Producers first; revisit only on real demand.
- No GraphQL, no gRPC.
- No new job storage. Every route reads or writes structures that already exist.

## Tests

- Auth: no token configured → routes absent (404, not 401). Wrong token → 401. Wrong scope → 403. Constant-time comparison asserted.
- **Drop-in (the headline test):** enqueue over HTTP, then byte-compare the Redis payload against `Wurk::Client#push` for the same input; and an integration test where a **stock Sidekiq** worker consumes an HTTP-enqueued job.
- Validation: oversized body, oversized args, unknown class under `strict_classes`, malformed `at`, unknown top-level key.
- Swarm: `GET /swarm` and `/processes` against a real forked swarm (integration, real Redis — never mock, `CLAUDE.md`); stale-heartbeat process reported `stale: true`.
- Mounting: all three modes — engine-nested, separately mounted, standalone Rack — serve the same routes and emit mount-correct URLs.
- Read-only mode (`WURK_WEB_READ_ONLY=1`) interaction: decide and test whether it also freezes the API (it should, for `admin`-scoped writes).
- `rake bench`: API off → within noise of main.

## Done when

- A non-Ruby process can enqueue, and a Wurk swarm runs the job.
- HTTP-enqueued payload is byte-identical to the Ruby path; stock Sidekiq consumes it.
- `GET /swarm` answers "how is the swarm working" without opening the dashboard.
- All three mount modes work and are documented in `docs/api-http.md`.
- No token → nothing mounted, nothing changed.
- One client library published with a runnable example.
