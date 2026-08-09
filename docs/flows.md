# Flows (DAG orchestration)

> **Wurk-only extra.** This is not a Sidekiq surface. Sidekiq Pro has
> [Batches](batches.md) — fan-out/fan-in with one completion callback — but
> nothing that expresses "run B after A and C both succeed" or pipes one
> job's result into the next. Going back to stock Sidekiq (or Sidekiq Pro)
> means hand-rolling that dependency tracking yourself: a counter, a lock,
> and a callback job, the exact machinery a flow replaces.

A **flow** is a directed acyclic graph of jobs: fan out, fan in, and run each
node only after everything it depends on has succeeded. It covers the same
ground as BullMQ's `FlowProducer`, Oban Pro Workflows, Celery `chord`, and
Hangfire continuations, in one API.

```ruby
Wurk::Flow.new do |f|
  a = f.job(FetchJob, 'https://a')
  b = f.job(FetchJob, 'https://b')
  f.job(MergeJob, depends_on: [a, b])   # runs after both succeed
end.run
```

## Contents

- [Why a flow is a batch, not a new tracker](#why-a-flow-is-a-batch-not-a-new-tracker)
- [Basic usage](#basic-usage)
- [Failure propagation](#failure-propagation)
- [No partial results](#no-partial-results)
- [Caps: nodes, depth, width](#caps-nodes-depth-width)
- [Cycle detection](#cycle-detection)
- [Abandonment](#abandonment)
- [Chains](#chains)
- [Visibility: dashboard and API](#visibility-dashboard-and-api)
- [The `Sidekiq::Flow` alias](#the-sidekiqflow-alias)
- [See also](#see-also)

## Why a flow is a batch, not a new tracker

**A flow node is one job, wrapped in its own batch.** `f.job(FetchJob, url)`
declares exactly one job, and that job's completion is observed through a
[batch](batches.md) holding exactly it. A batch is already the only thing in
Wurk that carries a success callback, a death cascade, subtree gating through
nesting, and a `Status` the dashboard already knows how to render — so a flow
is just the parent relation *between* batches. Nothing new counts jobs; the
one new piece of logic answers "are my parent's other dependencies done?",
not "how many jobs are left in this node?".

This has two practical consequences:

- A node has exactly one jid, so "the result of a node" is a well-defined
  thing, and `Wurk::Status.get(jid)` answers it (see
  [No partial results](#no-partial-results)).
- Unbounded fan-out belongs **inside** a node, not as thousands of sibling
  nodes: that node's job opens its own batch and enqueues however many
  children it likes, and batch nesting already blocks the node's `:success`
  on the whole subtree. Sibling nodes are for work with a different shape,
  not for parallelism — see [Caps](#caps-nodes-depth-width) for what happens
  if you reach for one anyway.

## Basic usage

The DSL is a block handed a builder. Each `f.job` call declares one job and
returns a handle other calls can depend on:

```ruby
Wurk::Flow.new do |f|
  a = f.job(FetchJob, url)
  b = f.job(FetchJob, other_url)
  f.job(MergeJob, depends_on: [a, b])       # runs after both succeed
end.run
```

`depends_on:` also takes node **names** — symbols or strings declared with
`name:` — including names declared *later* in the same block. That forward
reference is what lets a flow be built from configuration rather than a
literal graph, and it's also what makes a cycle expressible in the first
place (see [Cycle detection](#cycle-detection)):

```ruby
Wurk::Flow.new do |f|
  f.job(MergeJob, name: :merge, depends_on: %i[a b])   # forward reference
  f.job(FetchJob, url,       name: :a)
  f.job(FetchJob, other_url, name: :b)
end.run
```

`Wurk::Flow.new` only builds and validates the graph in memory — nothing
reaches Redis until `#run`. A refusal during construction (a cycle, a cap, a
bad name) leaves nothing behind. `#run` writes the whole graph and enqueues
every node with no dependencies in one atomic script; everything else waits
on a callback.

Other `f.job` options:

- `name:` — a symbol/string other nodes can address via `depends_on:`.
- `depends_on:` — a node handle, a name, or an array mixing both.
- `pipe:` — the one dependency whose stored result becomes this node's last
  argument; see [Chains](#chains). Implies `depends_on:` and can't be
  combined with it.
- Ordinary job options (`queue:`, `retry:`, `track:`, …) — merged into the
  payload the same way `perform_async` options are.

`Wurk::Flow#expires_in(duration)` overrides the retention on every key the
flow creates (default: the batch clock, 30 days). `Flow#run` returns `self`
with `fid`, `jids`, and `bids` populated (each array in node-declaration
order — `flow.jids[i]` is node `i`'s jid, whatever order the graph actually
runs in).

## Failure propagation

A node **fails** when its job reaches the dead set — retries exhausted, or a
`dead: false` discard. A retrying job hasn't failed; it just hasn't finished
yet.

On failure: the node's dependents never enqueue, and the flow's state
becomes `failed`, with the failing node's index recorded on the flow. This
falls out of the batch machinery for free — a batch whose job died fires
`:complete` but never `:success`, so "the parent never runs" needs no new
state. Death also already cascades up the batch parent chain, so an ancestor
can't silently succeed underneath a dead descendant.

It's recoverable without any special flow API: retrying the dead job out of
the morgue back to success clears the death mark on its own batch and on
every batch it cascaded to, and the flow resumes exactly where it stopped.
`failed` is a state a flow can leave, not a tombstone — it isn't even listed
among `Wurk::Flow::Status::TERMINAL_STATES`.

## No partial results

Because a node only ever runs once *every* dependency has succeeded, there's
no "which dependencies succeeded" question a node could ask — the answer is
always "all of them". A flow stores no partial-result set and no per-edge
failure payload.

What a node *can* see of its dependencies: the flow record holds every
node's jid, so any node's job may read any dependency's stored result with
`Wurk::Status.get(jid)` — see [job status tracking](job-status.md)
(`track:`) and [`GET /jobs/:jid`](api-http.md). This only answers for a
dependency whose class opted into `track: true`; an untracked dependency has
no row, and reading one returns `nil`, not an error.

Only the single-dependency case gets a result injected automatically — that
is exactly what a [chain](#chains) is. A fan-in node gets no synthesized
aggregate argument: building one would mean either an unbounded payload or a
silent truncation, and there is no version of that trade-off that isn't
lossy.

## Caps: nodes, depth, width

The builder enforces three constants before anything reaches Redis:

| Constant | Value | Bounds |
|---|---|---|
| `Wurk::Flow::MAX_NODES` | 1,000 | Total nodes in the graph. Creation is one atomic write, and the whole graph is that write's payload — each node costs a batch's worth of keys. |
| `Wurk::Flow::MAX_DEPTH` | 50 | The longest dependency path. Every level is a full callback hop (a job finishing, a callback job enqueued, fetched, and run), so depth is latency — and it's also the recursion depth of the death cascade. |
| `Wurk::Flow::MAX_WIDTH` | 100 | The most edges on either side of any one node. Fan-in bounds how many siblings can race the same parent's advance; fan-out bounds how many nodes one completion can enqueue at once. |

These are constants, not configuration — there's no host-level knob to raise
them. A graph that needs more is the wrong shape for a flow: a 100-way
fan-in, for instance, is a modelling error, not a scale requirement — those
100 units of work belong inside **one** node's own batch (see
[Why a flow is a batch](#why-a-flow-is-a-batch-not-a-new-tracker)), where
the batch machinery already handles any number of them for one flow-node's
worth of cost.

## Cycle detection

The builder validates the whole graph before writing a single key.
`Wurk::Flow::CycleError` is raised when the graph isn't acyclic, naming the
whole cycle path (for example `RootJob[:a] → RootJob[:b] → RootJob[:c] →
RootJob[:a] (→ reads "depends on")`) rather than just one node — a cycle is
only fixable if you can see which edge to delete.

`Wurk::Flow::LimitExceeded` is raised for any of the three caps above, and
names both the cap and the offending node.

Both are subclasses of `Wurk::Flow::InvalidGraph`, itself an `ArgumentError`
subclass. Validation is producer-side: the builder raises before `#run` writes
anything, in the process that declared the graph. The HTTP API has no flow
write route to raise through — `GET /v1/flows/:fid` is read-only and reports
lookup failures only.

The same validation pass also refuses: an empty flow (no `f.job` calls), a
duplicate node name, a `depends_on:`/`pipe:` naming something nothing
declares, and a handle that belongs to a different `Wurk::Flow` instance.

Note that `depends_on:` taking *only* handles returned by earlier `f.job`
calls can never express a cycle — every edge would point backwards in
declaration order. It's specifically the name-based forward reference (`f.job(B,
name: :b, depends_on: :a)`, `:a` declared later) that makes a cycle
expressible, and therefore makes this check load-bearing rather than
decorative.

## Abandonment

A flow does not wait forever. Two independent mechanisms cover the ways a
flow can get stuck:

- **TTL, not a reaper.** Every key a flow creates carries the same clock a
  batch does (30 days by default, `expires_in` to override), stamped once at
  creation. An abandoned flow simply disappears on its own — there's no
  sweeper thread and no leader election deciding whether it's "still alive".
- **An explicit kill switch** — `flow.abandon` or `Wurk::Flow.abandon(fid)`.
  It marks the flow `abandoned` (a terminal state) and releases its keys:
  every node record, every node's batch and subkeys, the dead-node set, and
  the batch index entries. The flow's own header record survives, marked
  `abandoned`, so a caller who asks "where did it go" gets an answer instead
  of a `404`.

Same caveat as `Batch::Status#delete`: abandoning does **not** chase
in-flight jobs out of their queues. A job already on a queue when you
abandon its flow will still run, and will still try to ack — against a batch
that's gone. Nothing that ack does can revive the flow.

Only a *live* flow can be abandoned; a flow that already succeeded or was
already abandoned is left as-is. `abandon` is idempotent: a retried call
after a lost reply finds the flow already terminal and writes nothing,
returning `false` even though the original call did apply — the flow record
is the source of truth, not the return value.

## Chains

A **chain** is a flow with one path through it, where every step is handed
the step before it's stored result:

```ruby
Wurk::Flow.chain do |c|
  c.job(FetchJob, 'https://example.com')
  c.job(ParseJob)                          # ParseJob#perform(fetch_result)
  c.job(StoreJob, 'reports')               # StoreJob#perform('reports', parse_result)
end.run
```

There's no separate machinery behind this — `Wurk::Flow.chain` is
`Flow::Builder`'s `pipe:` option applied to the previous step, once per
step. Everything a flow does (atomic creation, the caps, failure
propagation, `abandon`) applies unchanged, and a chain is still inspectable
as the graph it is. A chain built with `Flow::Chain#job` still returns a
node handle, so branching off a chain into a wider graph in the same block
is legal.

The pipe mechanics: a piped node's payload is stored with a sentinel string
in place of the argument it doesn't have yet, and on release the completion
script splices the upstream's stored result over those exact bytes — there's
no JSON decode/re-encode round trip on the way, which matters because that
round trip would otherwise be free to turn, say, a 64-bit id in a
*neighboring* argument into a double.

A pipe's source is always enqueued with `track: true`, whether or not the
job class or the caller asked for it — a pipe needs somewhere to read the
result from, and tracking is normally opt-in. An *explicit* `track: false`
on that source node is refused at build time rather than silently
overridden.

If the upstream result is missing, withheld (an `encrypt: true` job stores
no result to pipe), or exceeds the stored-result size cap and comes back
truncated, the link is marked **`broken`** with the reason recorded on the
node, the node is added to the flow's dead-node set, and the flow fails. A
chain doesn't pipe a wrong or truncated value where a correct one was
promised — a shortened *display* is lossy, a shortened *argument* is wrong,
so this fails loudly instead.

## Visibility: dashboard and API

Flows are visible in the dashboard's Flows list and per-flow detail page —
`app/controllers/wurk/api_controller.rb` backs `GET /api/flows`, `GET
/api/flows/:fid`, and `POST /api/flows/:fid/abandon` (the kill switch,
wired to the UI); `frontend/src/pages/Flows.tsx` lists them, and
`frontend/src/pages/FlowDetail.tsx` draws the DAG, including each node's
`broken` link reason where relevant.

The machine-facing HTTP API exposes a read-only `GET /v1/flows/:fid` — see
[`docs/api-http.md`](api-http.md#routes) for the full route table, response
shape and error codes. There's no `GET /v1/flows` listing and no way to
abandon a flow over that API: a producer holds the fid of the flow it
created, and deciding a flow is stuck enough to kill is an operator action
done with the graph on screen, in the dashboard.

Both surfaces read through the same class, `Wurk::Flow::Status` (and
`Wurk::FlowSet` for the listing), so the dashboard and the API can never
disagree about what state a flow is in.

## The `Sidekiq::Flow` alias

`Wurk::Flow` and `Wurk::FlowSet` are aliased as `Sidekiq::Flow` and
`Sidekiq::FlowSet` (`lib/wurk/compat.rb`). This is unusual for a Wurk-only
extra — most of them (like `Wurk::Status`) are deliberately **not** aliased
under `Sidekiq::`, since a name collision with a real Sidekiq or ecosystem
gem constant would be a silent behavior change on upgrade. `Flow` got the
alias only after checking: upstream Sidekiq defines no `Flow` anywhere in
`lib/` at the pinned parity SHA, RubyGems has no `sidekiq-flow` or
`sidekiq_flow` gem, and the only public `Sidekiq::Flow` in the wild is
nested under a different gem's own `Sidekiq` module. Same precedent-check as
`Sidekiq::Cron` and `Sidekiq::Status`.

## See also

- [`docs/plans/2026/08/07/101-beyond-sidekiq/11-flows.md`](plans/2026/08/07/101-beyond-sidekiq/11-flows.md) — the design doc, with the full reasoning behind every decision above.
- [`docs/batches.md`](batches.md) — the batch primitive flows are built on.
- [`docs/job-status.md`](job-status.md) — `track:` and `Wurk::Status`, what a node's dependents can read.
- [`docs/api-http.md`](api-http.md) — the machine-facing HTTP API, including `GET /flows/:fid`.
