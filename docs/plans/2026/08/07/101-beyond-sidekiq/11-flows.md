# 11 — Flows (DAG) & chains

> Part of [`overview.md`](overview.md). Depends on: 06 (chains pipe a result forward). Largest API addition in the plan — everything before it ships independently if this slips.
>
> **Additive invariant:** a new class alongside `Wurk::Batch`. Existing batches, callbacks, and nesting behave exactly as today. An app that never builds a flow never touches this code.
>
> **The five open questions are settled** in [Decisions (settled)](#decisions-settled). Read that section before touching flow code — every later step in this file assumes those answers.

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

`depends_on:` also takes node names, which may be declared later in the block — the form a flow built from configuration needs, and the one that makes a cycle expressible (decision 5):

```ruby
Wurk::Flow.new do |f|
  f.job(MergeJob, name: :merge, depends_on: %i[a b])   # forward reference
  f.job(FetchJob, url,       name: :a)
  f.job(FetchJob, other_url, name: :b)
end.run
```

Chains fall out of the same primitive — a linear flow where each node's result feeds the next (needs slice 06's stored return value).

## Decisions (settled)

The five questions this slice could not start without, answered before any flow code, with the reasoning. Decision 0 is the model the other five rest on. This section is the contract for the rest of the slice: changing an answer here is a plan change, not an implementation detail.

### 0. A node is one job, wrapped in its own batch

`f.job(FetchJob, url)` declares **one** job. Its completion is observed through a batch holding exactly that job, because a batch is already the only thing in Wurk that carries a success callback (`batch/callbacks.rb:129`), a death cascade (`:90`), subtree gating through `-pkids` (`:308`), and a `Status` the dashboard renders today. A flow is the parent relation between those batches. Nothing else tracks completion — the one new Lua call (step 3) answers "are my parent's other dependencies done?"; it does not count jobs.

Consequences, all load-bearing:

- A node has exactly one jid, so "the result of a node" is well defined and `Wurk::Status.get(jid)` answers it. That is what makes decision 2 and chains possible at all.
- Unbounded fan-out is expressed **inside** a node: that node's job opens its own batch and enqueues 50,000 children, and batch nesting already blocks the node's `:success` on the whole subtree. Fan-out is *not* expressed as 50,000 sibling nodes — see decision 3.
- A node inherits every batch behaviour for free, including invalidation, tags, `expires_in` and the dead-batch index. None of it is re-implemented.

### 1. Failure propagation — the parent never runs, the flow is marked `failed`

A node fails when its job reaches the dead set (retries exhausted, or a `dead: false` discard). A retrying job has not failed; it has not finished. On failure: dependents never enqueue, the flow's terminal state becomes `failed`, and the failure is visible on the flow record with the failing node's jid.

Why this and not per-edge policy:

- It is what the existing machinery already does. Advancement hangs off the node batch's `:success`, and a batch with a dead job fires `:complete` but **never** `:success` (`docs/batches.md:346-364`). "Parent never runs" needs no new state; every alternative needs a second signal to advance on, and a second signal to advance on is the second completion tracker this slice exists to avoid.
- Death already cascades up the batch parent chain (`callbacks.rb:90`), so an ancestor cannot silently succeed underneath a dead descendant. Flow-level `failed` is that cascade surfaced, not a parallel mechanism.
- It is recoverable without extra code. Retrying the dead job out of the morgue to success clears the batch's own death mark (#212) and every ancestor's cascaded one (#226), so the flow resumes from where it stopped. `failed` is a state, not a tombstone.

Rejected for v1 — BullMQ's four per-edge policies (`failParentOnFailure`, `removeDependencyOnFailure`, `ignoreDependencyOnFailure`, `continueParentOnFailure`). Three of the four make the parent run with an incomplete dependency set, which is exactly the partial-results problem decision 2 declines to take on. They stay possible later as a per-edge option; the default settled here is the only behaviour v1 has, and a flow that never opts in can never observe the difference.

### 2. Partial results — there are none, by construction

Decision 1 means a node runs only when *every* dependency succeeded. So there is no "which children succeeded" question to answer: the answer is always "all of them". v1 stores no partial-result set and no per-edge failure payload.

What a node can see of its dependencies:

- The flow record holds each node's jid, so any node may read any dependency's stored result with `Wurk::Status.get(jid)` — subject to that class having opted into tracking (slice 06 is opt-in per class; an untracked dependency has no row and reading one is `nil`, not an error).
- Only the single-dependency case injects a result automatically. That is the chain (step 4): one dependency, one jid, one result, passed as the next node's argument. A fan-in node gets no synthesised aggregate argument — building one would mean either an unbounded payload or a silent truncation, and slice 06 already fixed the size question at 8 KB with a `result_truncated` flag.
- A chain whose upstream result exceeds slice 06's cap **fails clearly** rather than piping a truncated value. Truncation here is not a lossy display, it is a wrong argument.

### 3. Depth and width — three build-time caps

Enforced by the builder, before anything reaches Redis. Each cap bounds a different failure mode, so all three exist:

| Cap | Value | Bounds |
|---|---|---|
| `Flow::MAX_NODES` | 1,000 | Total nodes. Creation is one atomic write (step 2), and Redis is single-threaded — the whole graph is the payload of that write, and a node costs a batch's ~9 keys. |
| `Flow::MAX_DEPTH` | 50 | Longest dependency path. Every level is one callback hop: a job finishing, a callback job being enqueued, fetched and run. Depth is latency, and it is also the recursion depth of `cascade_death`. |
| `Flow::MAX_WIDTH` | 100 | The most edges on either side of any one node. Fan-in bounds how many siblings race the same parent's advance call; fan-out bounds how many nodes one completion enqueues. |

A 100-node fan-in is a modelling error, not a scale requirement: those 100 units of work belong to **one** node's batch (decision 0), where they cost one flow node and the batch machinery already handles any number of them. The caps refuse the shape that buries Redis without refusing the workload.

The numbers are constants, not configuration. A knob here is a knob whose only correct setting is "the one that stops your graph from being refused", and a host that needs more than 1,000 nodes has a shape problem the cap is correctly reporting.

### 4. Dead-set interaction — TTL, not a reaper; `abandoned` is explicit

A dead node does not hold its parent forever, because decision 1 gives that flow a terminal state the moment the death cascades. There is no "waiting" flow to reap in the failure case.

For everything else — a queue flushed under a running flow, a node's job deleted by hand, a Redis restart mid-flight — two mechanisms, both already proven here:

- **Expiry, not sweeping.** Every flow key carries the batch clock: the 30-day default, `expires_in` to override, stamped `NX` at the site that creates the key, exactly as `batch.rb:379` and `Wurk::Status` do. An abandoned flow disappears on its own. No sweeper thread, no leader election, no second opinion about liveness.
- **An explicit `abandoned` terminal state and a kill switch** (`Flow#abandon`, step 6), surfaced in the dashboard and API. It marks the flow terminal and releases its keys. It does **not** chase in-flight jobs out of their queues — same caveat, and same wording, as `Batch::Status#delete`: jobs already queued will run and ack against a batch that is gone.

Rejected: a background reaper scanning for stuck flows. It is a second source of truth about whether a flow is alive, it needs a leader to run in exactly one process, and TTLs already do the job for free.

### 5. Cycle detection — at build time, and the DSL has to be able to express a cycle

The builder validates and raises before a single key is written: `Wurk::Flow::CycleError` names the whole cycle path (`A[:a] → B[:b] → C[:c] → A[:a]`), `Wurk::Flow::LimitExceeded` names the cap and the offending node, and both are `ArgumentError` subclasses so the HTTP API's existing 400 mapping (`api/jobs.rb:100`) covers them with no new arm.

The non-obvious half: **handles alone cannot express a cycle.** `depends_on:` taking only nodes returned by earlier `f.job` calls makes every edge point backwards in declaration order, so the graph is acyclic by construction and a cycle check is decorative code that no test can reach. So `depends_on:` also takes a node **name** (`f.job(B, name: :b, depends_on: :a)`), which may be declared later in the block — a forward reference, which is how flows get built from configuration rather than from a literal block, and which is the shape Oban Pro's `deps:` uses. Names are what make a cycle expressible, and therefore what make the check load-bearing rather than ceremonial.

Also refused at build time, for the same reason and with the same error: an empty flow, a duplicate node name, a dependency on a name nothing declares, and a handle belonging to a different flow.

## Files to change

- new `lib/wurk/flow.rb`, `lib/wurk/flow/` (node, builder, completion), `lib/wurk/lua/flow_*.lua`.
- `lib/wurk/keys.rb` — flow key prefixes (new keys only).
- `lib/wurk/batch/callbacks.rb` — extension point for "callback enqueues the parent node"; **do not** change existing callback semantics.
- `lib/wurk.rb` — `Sidekiq::Flow` alias only if no upstream/ecosystem name collides. This is a Wurk extra, not parity — check first.
- Dashboard: a flow view (graph + per-node state) — `app/controllers/wurk/api_controller.rb` + a new SPA page under `frontend/src/pages/`.
- API: `GET /flows/:fid` in slice 07's surface.

## Steps

1. ~~Write the decisions above into the top of this file first, with reasoning.~~ Done — [Decisions (settled)](#decisions-settled). Shipped with the builder: `flow.rb`, `flow/node.rb`, `flow/builder.rb`. `flow/completion.rb` belongs to step 3, where it has behaviour; an empty one now would be a stub with no reader.
2. Builder: construct the whole graph, validate (cycles, depth, width), then **create atomically** — a partially-created flow whose parent can never fire is worse than a rejected one. `batch/buffer.rb` already does atomic creation for the one-level case; extend that pattern.
3. Node completion: reuse batch success callbacks. The callback resolves "are all my parent's other dependencies done?" in **one Lua call** — a read-then-decide races when two siblings finish simultaneously. This is the correctness core of the slice; test it under real concurrent forks.
4. ~~Chains: linear flow + slice 06's stored result as the next node's argument.~~ Done — `pipe:` on `Flow::Builder#job`, `Wurk::Flow.chain` for the all-linear case, `flow/chain.rb`. Creation stores a piped node's payload with a sentinel where the argument goes and `flow_advance.lua` splices the upstream's stored result over those bytes, so no cjson round trip touches the neighbouring arguments. A pipe's source is enqueued `track: true` whether or not the caller said so; an *explicit* `track: false` on it is refused instead. Slice 06's cap is respected by refusing it: a truncated, withheld or missing result marks the link `broken` with the reason on its record, adds it to the flow's dead-node set and fails the flow — piping the head would hand the job a wrong argument it would succeed on.
5. Dashboard: flow graph with per-node state, reusing the existing SPA patterns (lazy-loaded route + `components/Skeleton.tsx` fallback, per `CLAUDE.md`). Surface `abandoned` and a node's `broken` reason alongside the other states.
6. ~~Kill switch: a way to abandon a stuck flow, releasing its keys.~~ Done — `Wurk::Flow.abandon(fid)` / `Flow#abandon`, `lua/flow_abandon.lua`. Drops every node record, every node batch and its subkeys, the dead-node set and both batch-index entries; the flow's own record survives marked `abandoned` on the clock it was created with, because that record is also the guard every in-flight completion claims against. Wiring it to a route belongs to step 5.

`Sidekiq::Flow` is aliased (`compat.rb`): upstream Sidekiq defines no `Flow` anywhere in `lib/` at the pinned parity SHA, RubyGems has no `sidekiq-flow`/`sidekiq_flow` gem, and the only `Sidekiq::Flow` in public Ruby is nested under a gem's own `Sidekiq` module. Checked before adding, per the `Sidekiq::Cron` (#204) and `Sidekiq::Status` precedents.

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
