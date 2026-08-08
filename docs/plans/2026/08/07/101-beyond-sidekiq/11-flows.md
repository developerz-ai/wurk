# 11 — Flows (DAG) & chains

> Part of [`overview.md`](overview.md). Depends on: 06 (chains pipe a result forward). Largest API addition in the plan — everything before it ships independently if this slips.
>
> **Additive invariant:** a new class alongside `Wurk::Batch`. Existing batches, callbacks, and nesting behave exactly as today. An app that never builds a flow never touches this code.

## Why

One API covers four prior arts at once ([`00-census.md`](00-census.md)): BullMQ `FlowProducer` parent-child, Oban Pro Workflows, Celery `chord`, Hangfire continuations. It's the most-requested capability Sidekiq Pro doesn't have — and Wurk is already 80% of the way there, because **a batch is a one-level flow**.

## Build on batches, not beside them

`lib/wurk/batch/` already owns: atomic creation (`buffer.rb`), success/complete/death callbacks (`callbacks.rb`, `callback_job.rb`), the "neither success nor failure" rescue taxonomy (`server_middleware.rb:56`), nesting, progress (`status.rb`), and death handling (`death_handler.rb`). A flow node is a batch whose success callback enqueues the parent. Reuse that machinery; do not write a second completion tracker — two trackers that can disagree is the failure mode here.

Read `docs/target/sidekiq-pro.md` (Batches) and `docs/batches.md` before designing the API.

## Shape

```ruby
Wurk::Flow.new do |f|
  a = f.job(FetchJob, url)
  b = f.job(FetchJob, other_url)
  f.job(MergeJob, depends_on: [a, b])       # runs after both succeed
end.run
```

Chains fall out of the same primitive — a linear flow where each node's result feeds the next (needs slice 06's stored return value).

## Decisions to settle before code

1. **Failure propagation.** A child fails permanently (lands in the dead set) — does the parent never run, run anyway, or run with a failure marker? BullMQ offers fail/continue/remove per edge. Recommend: default = parent never runs, flow marked failed; make it configurable per edge later, not now.
2. **Partial results.** With `continue`, the parent needs to see which children succeeded. Ties to slice 06 storage and its size cap.
3. **Depth and width limits.** "Unlimited nesting" (BullMQ's claim) plus callbacks means an accidental fan-out can bury Redis. Cap both; fail loudly at build time, not at runtime.
4. **Dead-set interaction.** A dead child holds its parent forever. Needs a TTL/reaper, or an explicit "flow abandoned" terminal state visible in the dashboard.
5. **Cycle detection** at build time — a DAG builder that accepts a cycle deadlocks silently.

## Files to change

- new `lib/wurk/flow.rb`, `lib/wurk/flow/` (node, builder, completion), `lib/wurk/lua/flow_*.lua`.
- `lib/wurk/keys.rb` — flow key prefixes (new keys only).
- `lib/wurk/batch/callbacks.rb` — extension point for "callback enqueues the parent node"; **do not** change existing callback semantics.
- `lib/wurk.rb` — `Sidekiq::Flow` alias only if no upstream/ecosystem name collides. This is a Wurk extra, not parity — check first.
- Dashboard: a flow view (graph + per-node state) — `app/controllers/wurk/api_controller.rb` + a new SPA page under `frontend/src/pages/`.
- API: `GET /flows/:fid` in slice 07's surface.

## Steps

1. Write the decisions above into the top of this file first, with reasoning.
2. Builder: construct the whole graph, validate (cycles, depth, width), then **create atomically** — a partially-created flow whose parent can never fire is worse than a rejected one. `batch/buffer.rb` already does atomic creation for the one-level case; extend that pattern.
3. Node completion: reuse batch success callbacks. The callback resolves "are all my parent's other dependencies done?" in **one Lua call** — a read-then-decide races when two siblings finish simultaneously. This is the correctness core of the slice; test it under real concurrent forks.
4. Chains: linear flow + slice 06's stored result as the next node's argument. Respect slice 06's result size cap — a chain passing a large payload must fail clearly, not truncate silently.
5. Dashboard: flow graph with per-node state, reusing the existing SPA patterns (lazy-loaded route + `components/Skeleton.tsx` fallback, per `CLAUDE.md`).
6. Kill switch: a way to abandon a stuck flow from the dashboard/API, releasing its keys.

## Tests

- Unit: diamond graph (A,B → C) fires C exactly once, after both.
- **Concurrency: siblings finishing simultaneously across real forks fire the parent exactly once.** The race this slice exists to get right.
- Failure: dead child → parent doesn't run, flow marked failed, keys reaped.
- Build-time: cycle rejected; depth/width caps rejected; partially-built flow never persists.
- Chains: result piped; oversized result fails clearly.
- Nested flows and flows-inside-batches don't corrupt batch state; existing batch tests unchanged.
- Integration: real Redis, real forks, a 3-level flow to completion.
- `rake bench`: no flows in use → within noise.
- Coverage ≥90/90 including the branchy completion logic.

## Done when

- A DAG with fan-out and fan-in executes in dependency order, parent fires exactly once.
- Simultaneous sibling completion across processes is race-free (proven under forks, not mocked).
- Failure, cycle, depth, and abandonment cases all have defined, tested behavior.
- Existing `Wurk::Batch` behavior and tests are untouched.
- Flow state visible in dashboard and API.
