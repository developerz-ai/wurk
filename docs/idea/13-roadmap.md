# Roadmap

Ship parity incrementally. Every milestone produces a usable gem.

## M0 — Skeleton

- Gemspec, engine class, version, MIT license.
- Dummy Rails app under `test/dummy/` boots.
- Minitest parallel runner configured.
- CI workflow green on a smoke test.
- Docs site (`docs/site/`, hand-written static HTML — not VitePress; a
  VitePress build was never adopted) published to GitHub Pages.

## M1 — Core processor

- Wurk::Worker plus perform_async, perform_in, perform_at.
- Redis schema matching Sidekiq OSS — queue lists, schedule zset, retry zset, dead zset.
- Reliable BLMOVE fetcher.
- Manager thread pool.
- Fork-based swarm with SIGTERM graceful drain.
- Sidekiq compat aliases so existing apps work unchanged.
- Acceptance: existing Sidekiq jobs in a real Redis run untouched.

## M2 — Web dashboard parity

- Engine mounted at `/wurk`.
- Precompiled SolidJS SPA bundle baked into the gem.
- Parity panes: dashboard, queues, retries, scheduled, dead, busy.
- SSE live updates.

## M3 — Pro parity

- Batches and callbacks.
- Reliable client with Redis-outage buffer.
- Queue pause and resume.
- Job expiry option.
- Statsd metrics emitter.
- Web UI search.

## M4 — Enterprise parity

- Rate limiters (concurrent, window, bucket).
- Cron with leader election (fencing token).
- Unique jobs (until_executed, until_executing, until_and_while_executing).
- Encryption (AES-256-GCM with key rotation).
- Historical metrics (time-series).
- Rolling restart logic on SIGUSR1.

## M4.5 — Beyond Sidekiq (shipped)

Features with no Sidekiq/Pro/Ent equivalent — extras other queue systems
(BullMQ Pro, Oban Pro, pg-boss, River) have and Sidekiq doesn't. Full detail,
decisions, and measurements: `docs/plans/2026/08/07/101-beyond-sidekiq/`.

- Interrupted-`IterableJob` metrics fix — books `p`+`ms`, never `f` (#394).
- Dashboard locale negotiation (server hint + client override) and Intl-based
  date/time/duration formatting, incl. a timezone picker.
- Dashboard light theme, three-state (`light`/`dark`/`system`), no
  performance cost.
- OpenTelemetry tracing (`Wurk::Telemetry`) — W3C `traceparent` propagation
  from enqueue through execute, opt-in, zero cost when off.
- Job status, progress, and results (`Wurk::Status`) — `track:` opt-in,
  coalesced in-job writes, encryption-aware result withholding.
- Machine-facing HTTP API (`Wurk::API`) — produce + observe planes, bearer
  auth with scopes, idempotency keys, three mount modes, a reference Python
  client.
- Per-job `timeout:` and `deadline:`, backed by one lazily started monotonic
  watchdog thread per capsule, never armed (so free) unless a job declares a
  bound.
- Debounce (`collapse: { policy: :debounce }`) and throttle-to-slot
  (`collapse: { policy: :throttle }`) — burst collapsing and rate ceilings at
  enqueue time, atomic single-Lua-call implementations.
- Global per-queue concurrency (`config.global_concurrency`) — a cluster-wide
  cap enforced at fetch time, folded into the existing pipelined fetch so it
  costs nothing when unset.
- Flows (`Wurk::Flow`) — a DAG of batches with `depends_on:`, chained
  results (`pipe:`), and an abandon kill switch.

## M5 — AI dashboard

- Anomaly detection.
- Natural-language queue queries.
- Error triage clustering.
- Capacity advisor.

## M6 — 1.0

- Migration guide finalized.
- Benchmark suite published with comparisons to stock Sidekiq.
- Full YARD API reference auto-generated to the docs site.
- Tag 1.0.0, push to RubyGems.

## Stretch (post-1.0)

- Worker topology DSL (specialized swarm slots).
- io_uring fetch path on Linux.
- ActiveJob adapter beyond the default.
- Helm chart and Kubernetes operator.
