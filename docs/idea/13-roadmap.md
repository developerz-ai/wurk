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

1.0.0 was tagged and published to RubyGems on 2026-06-11 (`CHANGELOG.md`); the
1.x line has shipped continuously since. Where each original exit criterion
actually stands:

- Benchmark suite published with comparisons to stock Sidekiq — **done**
  (`docs/benchmarks.md`, `rake bench:vs_sidekiq`; the numbers show Wurk at
  roughly 0.87×–1.02× of stock Sidekiq, not faster).
- Full YARD API reference auto-generated to the docs site — **done**
  (<https://developerz-ai.github.io/wurk/api/>).
- Tag 1.0.0, push to RubyGems — **done**.
- Migration guide finalized — **not yet**. The guide carries a production
  cutover and rollback procedure (drain cutover), but two proofs it depends on
  are still open: Pro/Enterprise Redis formats validated against a dump from a
  real Pro/Ent deployment, and a mixed Sidekiq + Wurk fleet on one Redis. Until
  both exist the guide supports drain cutover only. Tracked in
  `docs/plans/2026/10/04/101-squeaky-clean-audit/09-production-readiness.md`
  (R2, R4).

## Stretch (post-1.0)

- Worker topology DSL (specialized swarm slots) — shipped early as
  `Wurk::Topology` / `config.topology`.
- io_uring fetch path on Linux.
- ActiveJob adapter beyond the default.
- Helm chart and Kubernetes operator.
