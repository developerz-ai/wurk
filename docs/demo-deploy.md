# Demo deployment (wurk.demo.developerz.ai)

The public demo is the [`demo/`](../demo) Rails 8 app — it mounts the Wurk
dashboard and runs a [producer](../demo/app/workloads/demo_producer.rb) that
exercises cron, unique, batch, rate-limited, and failing jobs so every widget
shows live, churning data. The dashboard runs **read-only**
(`WURK_WEB_READ_ONLY=1` + a `Wurk::Web.configure` guard): every mutating endpoint
returns 403 at the middleware layer, not just hidden in JS.

## Architecture

One image (`Dockerfile`), two roles via `bin/demo-entrypoint`:

| Role | Process | Notes |
|---|---|---|
| `web` | puma serving the read-only dashboard **+** the workload generator | `WURK_DISABLED=1` keeps the swarm out of this process; `WURK_DEMO_PRODUCER=1` — set by this branch only — starts the generator thread (a Redis-holding thread must never be forked). |
| `worker` | the Wurk swarm that drains the generated jobs | `WURK_DISABLED=1` too, so the railtie stays out; the entrypoint runs `Wurk::Swarm#boot` + `#supervise` itself on the main thread so SIGTERM drains promptly. `WURK_COUNT` defaults to 2: core detection reads the cgroup's CPU *limit*, and a CPU request alone leaves it unbounded, so the default would be the node's 6 cores. |

Any other argument is exec'd verbatim from `demo/` with neither swarm nor
generator — that is how the reset CronJob runs `bundle exec rails demo:reset`.

Both connect to Redis via `REDIS_URL`. A reset/seed (the generator self-heals on
a Redis flush) keeps the demo from ever looking dead — a flush of the demo Redis
is enough; the generator re-seeds within one tick. To stop queue latency from
creeping up over hours (the single worker can't drain everything the producer
tops up), an hourly `CronJob` flushes the demo Redis by running the
`demo:reset` rake task. Its manifest lives in the infrastructure repo:
[`stacks/apps/wurk-demo/manifests/cronjob-reset.yml`](https://github.com/developerz-ai/infrastructure/blob/main/stacks/apps/wurk-demo/manifests/cronjob-reset.yml).

```text
            ┌── web (puma)  ──► read-only dashboard + generator ──┐
internet ──►│                                                     ├──► Redis
            └── worker (swarm) ──► drains jobs ───────────────────┘
```

## Optional soak operation

Soak is separate from the ordinary `DemoProducer` showcase described above.
It is additive, never auto-enabled, and does not replace the hourly reset or
change the showcase Retries target (4), Dead target (5), or the worker queue
priority (strict `high` → `default` → `low`); soak jobs use `low`.
See the [demo README](../demo/README.md#optional-soak-traffic)
for the local command and cycle details.

### Web-only opt-in

To enable, add `WURK_DEMO_SOAK=1` to the **web Deployment only** and roll it out.
Do not add it to shared image defaults, the worker Deployment, or reset jobs.
The producer requires `WURK_DEMO=1`, `WURK_DISABLED=1`,
`WURK_DEMO_PRODUCER=1`, and `WURK_DEMO_SOAK=1`, all exact string matches. Its
process must be the nonforking web process: worker and passthrough roles and
forked children cannot produce soak cycles. Workers only execute the jobs.
The web entrypoint enables the ordinary showcase producer, not the soak opt-in.

To disable, remove the soak flag from web and roll out web again. Values such
as `0` or `true` do not enable it. Previously admitted work may still finish;
disabling is not a purge. Leave the existing reset CronJob and showcase targets
unchanged. With the flag absent, normal demo traffic and read-only dashboard
behavior remain unchanged.

### Work and safety envelope

Admission starts a bounded exercise, not a declaration of success. Verify
recoverable retries and scheduled jobs complete, cron executes, both batch
members and both complete/success callbacks run, uniqueness suppresses
duplicates, and bucket limiting reschedules work that later completes.
Registration or enqueueing alone does not demonstrate these outcomes, and a
cycle returning `true` does not establish successful recovery. Soak payloads
allow at most two retries with `dead: false`; they do not permanently fill Dead.

The producer waits 60 seconds after each cycle attempt. Admission counts queued
jobs across `high`, `default`, and `low` plus retry and scheduled entries and
reserves 12 slots, including callback wrappers and recovery: the resulting total
must stay below 40, with fewer than 10 tracked soak batches. A cycle submits a
retry job, a job delayed by 2 seconds, two batch members, two identical unique-job
submissions (30-second uniqueness), and three bucket-limited jobs, alongside
bounded recovery work. Cron uses the real enqueue path with an unpersisted loop
whose schedule expression is `* * * * *`, explicitly fired by each admitted
cycle. The expression does not create independent minute-by-minute fires, and
there is no persistent soak cron registration permitting autonomous leader
fires outside that guard. Enqueueing establishes neither cron history nor
successful execution; verify execution of the tagged job separately. The bucket
allows two jobs per minute with at most two limiter reschedules. Bookkeeping, batch
expiry/linger, and limiter retention use 300-second TTLs; later backlog checks
prune expired tracked batch indexes.

These limits live in [`demo_soak.rb`](../demo/app/workloads/demo_soak.rb) and
[`soak_job.rb`](../demo/app/jobs/soak_job.rb). Treat these bounded budgets as
part of capacity planning, not as permission to raise ordinary demo targets.

Memory admission is fail-closed. Redis `used_memory` must be strictly below
the smaller of 80% of configured `maxmemory` and 128 MiB (134,217,728 bytes).
With `maxmemory=0`, the ceiling is 128 MiB; equality pauses admission too.
The limits are producer admission guards, not changes to Redis eviction
configuration. Failed, missing, or malformed memory probes pause admission of
new cycles just as memory pressure does, including their cron submissions. The
unpersisted cron loop cannot keep producing between guarded cycles. Memory and
backlog checks govern new-cycle admission, not the execution of previously
admitted work: queued, scheduled, retried, and executing jobs, limiter
reschedules, and batch callbacks may still drain on workers.
A later valid, below-threshold probe permits admission to resume once backlog
is also within bounds and dashboard probes pass. This pause does not disable
`DemoProducer`; inspect Redis usage and backlog before increasing capacity, and
do not bypass the guard to force traffic.

The restart exercise coordinates an in-flight soak job with one eligible
registered worker restart via Wurk's process control, with replacement handled
by swarm supervision. Eligibility requires tag `demo`, a nonembedded worker
that is not stopping, and a heartbeat newer than 30 seconds ago. The producer
checks eligibility again for the worker that recorded starting the original
JID before requesting its stop. TERM shutdown can requeue unfinished private-list
work before killing its threads; this is not by itself proof of orphan reclamation.
Inspect `demo-soak:<token>:started` for the JSON worker identity and original JID
and `demo-soak:<token>:recovered` for that same JID; both expire after 300 seconds.
The `[demo-soak] recovery <jid>: verified` log records only that comparison; a
missing log or `not observed` does not verify recovery. To establish supervised
replacement, require regression evidence of a different worker identity,
completion of the original `demo-soak`-tagged JID, and its removal from queued
and private-list fetch custody. A stop request, replacement heartbeat, or fresh
substitute job's completion is insufficient. The same-child Manager/Processor
recovery test does not demonstrate swarm replacement, and these operational
requirements are not a claim that the supervised regression or deployment checks
have passed. The producer waits at most 5 seconds
for the job to start and then at most 50 seconds for recovery evidence, with no
substitute-job retry loop. These waits remain within the same backlog and
retention budgets; an unavailable worker, bounded failure, or exhausted completion wait does not
verify recovery and must not trigger extra recovery jobs. Web does not send
signals to foreign OS PIDs, restart every worker, or require access to the worker
pod's PID namespace.

Dashboard probes use a fixed local allowlist of **GET-only** Rails-mounted
`/wurk/api` paths: stats, queues, retries, scheduled, dead, processes, batches,
limiters, and cron. Requests go to `127.0.0.1` on `PORT` (default 3000), with
1-second connect, read, and write timeouts and no redirect following. Only
HTTP 200 with a JSON object or array passes; a failed probe prevents admission.
They do not target the public host or configurable remote URLs, and
`Wurk::Web.call` is not the dashboard API. No dashboard write endpoints or
read-only exemptions are needed.

### Marker and error suppression

Every soak-generated job carries `tags` containing `demo-soak`: immediate,
scheduled, cron, retried and batch members, plus generated callback wrappers.
The marker is also passed in callback options. Demo-only middleware bridges
that payload marker into the job's scoped Sentry tags as `demo-soak=soak`, because
Wurk's job-context allowlist does not forward payload tags. The existing central
`DemoSentryPolicy` recognizes a tag key or value equal to `soak` after trimming
and lowercasing; `demo-soak=true` alone is not recognized. Client tagging covers
the soak job family and wrappers targeting the soak callback; the server bridge
checks the payload's `demo-soak` marker. Its scope must cover error capture without
leaking the marker into subsequent unmarked jobs.

Reporting still requires exactly `WURK_DEMO_REPORT_ERRORS=1` and a nonblank
`SENTRY_DSN`. The central policy drops marked events; unmarked errors retain its
existing privacy protections and credential scrubbing, including suppression
of the showcase's intentional `BrokenJob` and `FlakyWebhookJob` failures.
Soak suppression does not replace the policy or disable reporting globally.
A memory-pressure pause, failed probe, or bounded execution failure is an
operational condition to inspect, not evidence that a cycle exercised all
features successfully.

## Deploy: who can trigger it

`.github/workflows/deploy-demo.yml` **builds and pushes the image** — it holds
no cluster credentials — and then **records the deploy as a GitHub Deployment
object and waits, bounded, for the demo to serve the new version** (see
[Deployment record and version probe](#deployment-record-and-version-probe)).
The in-cluster **ArgoCD Image Updater** selects the
newest DOCR tag matching `^sha-[0-9a-f]{7}$` and syncs the deployment
automatically; the pushed digest
*is* the deploy trigger. It runs three ways — automatically on every push
to `main` that changes what the image runs (lib/app/frontend/demo/Dockerfile;
the demo tracks main), `workflow_dispatch` by hand, or called by `release.yml` after it publishes the gem for a
`lib/wurk/version.rb` bump landing on `main` (the tag is an output there, cut
last; see [RELEASE.md](../RELEASE.md)). The hand-dispatched door is gated two
ways so only approved deployers (the `DEMO_DEPLOYERS` list) can ship an image
through it, with a third gate available but not configured; the other two
doors skip the allowlist because the commit already passed branch protection
on `main`:

1. **Public repo + `workflow_dispatch`** → only users with *write* access (org
   members) can trigger it; external forks cannot.
2. **`DEMO_DEPLOYERS` repo variable** (comma-separated GitHub usernames) → the
   `authorize` job rejects anyone not listed. Guards the `workflow_dispatch`
   door only: a run called by `release.yml` passes `trusted: true`, which waives
   the allowlist (honoured only from the `release` workflow on `main`) — by then
   that caller has already published this commit's gem.
3. **`demo` environment** → not a gate today: it carries no protection rules
   (`gh api repos/developerz-ai/wurk/environments/demo` returns
   `protection_rules: []`), so no run waits for an approver. Adding Required
   Reviewers would make it one. The environment sits on the `build` job (not a
   separate deploy job) because the digest push is what triggers the deploy, so
   approval would have to pause the run *before* the image ships.

### Deployment record and version probe

The deploy is **indirect**: CI pushes an image and Image Updater syncs the
newest digest. Nothing in CI observed the result, so a demo could sit on a
stale digest for weeks with every run green — which is how it went stale
across several releases. After the image push, the `build` job therefore:

1. **Records a GitHub Deployment** for the `demo` environment whose `ref` is
   the built commit (`steps.built.outputs.sha` — the SHA of the checked-out
   ref, not `github.sha`, which is the SHA the *workflow* was loaded from).
   `gh api repos/{owner}/{repo}/deployments` then lists a `demo` deployment at
   that commit, and the demo environment's deployments tab shows it. The
   pushed digest is what actually deploys, so this object records the intent
   and its outcome — it triggers nothing.
2. **Waits, bounded, for the demo to serve the image's bundled version**: it
   polls `https://wurk.demo.developerz.ai/wurk/api/meta` and compares the
   reported `version` against the version the built image bundles. The loop
   has an explicit upper bound on attempts (with a sleep between them), so a
   demo that never catches up fails the run with a recorded status instead of
   hanging until the job timeout. Every poll is also deadline-bounded
   (`--connect-timeout` / `--max-time`): a demo that accepts the connection
   but stalls the response costs its request deadline per attempt instead of
   blocking until the job timeout — which would leave the Deployment
   `in_progress` with no failure status and no last-version diagnostic. The
   window the loop can cover includes request time, so its worst case stays
   inside the job's timeout alongside the image build and push.

The probe compares **versions, not commit SHAs**. The demo serves the *gem*
version: `/wurk/api/meta` renders `::Wurk::VERSION`
([`app/controllers/wurk/api_controller.rb`](../app/controllers/wurk/api_controller.rb)),
and the image installs the demo app's bundle from
[`demo/Gemfile.lock`](../demo/Gemfile.lock) frozen. The expected side is read
from that lock's path-sourced `wurk (...)` version — the version the built
image actually bundles — rather than from the checkout's
[`lib/wurk/version.rb`](../lib/wurk/version.rb), which can differ on an
ordinary push that changes app or lib code without a version bump. Reading
the expected side from the bundle keeps the probe aligned with what the
running image serves; a hardcoded version would pass while the demo served
another one. There is no endpoint on the demo that reports a commit SHA, so
the Deployment's commit ref and the served-version probe are deliberately
different checks: the first records what CI built, the second proves what the
demo is actually running.

**This is the CI probe's expected side, and it is not the only one.** The
standalone read-only check in [The served-version check
(read-only)](#the-served-version-check-read-only) answers a different
question — "does the demo serve *this checkout's* version?" — and therefore
reads its expected side from `lib/wurk/version.rb` instead of the lock. The
two disagree by design: CI asks whether the *image it just built* is the one
being served, the standalone check asks whether the *checkout* is what the
demo runs. A push that changes app or lib code without a version bump moves
the two apart, and that gap is exactly what each one is there to report.

The outcome is written back to the Deployment:

| Probe result | Deployment status | Job |
|---|---|---|
| the reported version matches | `success` | green |
| the bound is exhausted | `failure` | red — the run log prints the last version the demo reported, so the reader knows what it was actually serving |

A rollout can answer `/wurk/api/meta` with HTML or an empty body for a
moment; that reads as "no version yet" and the probe retries rather than
aborting on a transient blip.

**Permissions.** The `build` job holds `contents: read` plus
`deployments: write` — the second is the only growth, and it exists solely to
create the Deployment and post its statuses. The workflow-level block and the
`authorize` job are unchanged (`contents: read`): no `id-token`, no
`actions: write`.

### The served-version check (read-only)

This is a second, independent check — not the CI probe above. The CI probe
compares the demo against the version the *image it just built* bundles; this
one compares the demo against the version *this checkout* declares. The demo's
own endpoint answers both:

```text
GET https://wurk.demo.developerz.ai/wurk/api/meta
```

It is **public, unauthenticated, and GET-only** — no token, no session, no
header. It answers with the running gem's version: `/wurk/api/meta` renders
`version: ::Wurk::VERSION`
([`app/controllers/wurk/api_controller.rb`](../app/controllers/wurk/api_controller.rb),
line 53), so the payload reports the version the *running* process booted with.

The expected side is read from this checkout's
[`lib/wurk/version.rb`](../lib/wurk/version.rb) — the same extraction the
release check uses, so the two never drift apart:

```bash
grep -oE "[\"'][0-9][^\"']*[\"']" lib/wurk/version.rb | head -1 | tr -d "\"'"
```

That is deliberately **not** the CI probe's expected side. The CI probe reads
the version out of [`demo/Gemfile.lock`](../demo/Gemfile.lock) — the gem the
built image actually installs — because it asks whether the image it built is
the one being served. This check asks whether the *checkout* is what the demo
runs, so it reads `lib/wurk/version.rb`. A push that changes app or lib code
without a version bump moves the two apart, and each check reports the gap
from its own side.

Comparing the two gives exactly three verdicts:

| Verdict | What it means | Grade |
|---|---|---|
| **match** — the reported `version` equals the extracted one | the demo is serving this checkout's version | healthy (`success`) |
| **mismatch** — the probe answered with a parsable `version` that differs | the demo is serving a *different* version than the checkout — a stale digest, or a deploy that never landed | **not healthy** (`Unhealthy`), naming both the served version and the expected one |
| **unavailable / invalid** — the transport failed, the status was not 200, the body was not exactly one JSON object (leading or trailing garbage included), or the JSON carried no usable `version` | the probe could not establish anything | `verdict unknown` — **never** a green and never a success; the next checkup re-runs it |

An unreachable probe is explicitly **not** healthy: "I could not tell" is not
"it is fine", and it must never be reported as a match. The mismatch verdict
names both sides because the two numbers are the whole diagnosis — the version
being served and the version that was expected. The probe itself is
deadline-bounded (`--max-time 5`), the same per-request bound the CI probe
carries: a demo that accepts the connection but stalls the response costs its
request deadline and grades `verdict unknown` like any other transport failure,
instead of blocking the scheduled checkup.

**This check is READ-ONLY.** It holds no cluster credentials, no `DOCR_TOKEN`
and no `ARGOCD_*` secret; it needs no GitHub token and no deployment
authority, and it grants none. It reads one public JSON endpoint and grades
what came back — it cannot build an image, push a tag, sync an ArgoCD
Application, or change anything the demo serves. The demo app is read-only in
the same sense: `c.read_only = true`
([`demo/config/initializers/wurk.rb`](../demo/config/initializers/wurk.rb))
plus `WURK_WEB_READ_ONLY=1` makes every mutating endpoint 403 at the
middleware layer, so even a request that tried to mutate the demo would be
refused. The health checkup that runs this probe sends a GET and nothing else.

### One-time GitHub setup (repo admin)

- **Settings → Secrets and variables → Actions → Variables:** add
  `DEMO_DEPLOYERS` = e.g. `sebyx07,din-handle,ivann-handle`.
- **Settings → Environments → `demo`:** create it. Optional and not applied
  on this repo today: add the deployer(s) as *Required reviewers*, and restrict
  the deployment branch to `main`.

- **Settings → Environments → `demo` → Environment secrets:** add `DOCR_TOKEN`
  (a DigitalOcean token with registry write). It lives on the environment, not
  the repo, so only the `build` job, which enters that environment, can read it —
  this repo is public.

No `ARGOCD_*` secrets are needed — CI never talks to the cluster.

### Registry

The image is pushed to `registry.digitalocean.com/developerz-ai/wurk-demo`
only, tagged `sha-<7>` (what Image Updater selects on), `<sha>`, and `latest`
(the last two are for humans and rollback). Infra moved the demo off GHCR on
2026-07-12 (infra #803); `stacks/apps/wurk-demo/manifests/kustomization.yml`
rewrites every image ref onto DOCR.

### Error reporting

The demo reports errors to Sentry, and only when it is told to. Reporting turns
on **only** when `WURK_DEMO_REPORT_ERRORS=1` *and* `SENTRY_DSN` is set to a
non-empty value. With the flag alone, the DSN alone, or neither, the demo never
requires the SDK, never initialises Sentry and never installs the Wurk
integration — Wurk's server middleware and error handlers stay exactly as they
were, and the demo's bundle carries `sentry-ruby` / `sentry-rails` without ever
loading them.

When it is on, web errors go through `sentry-rails` and job failures through
[`Wurk::Sentry`](sentry.md), installed straight onto `Wurk.configuration` in
[`demo/config/initializers/sentry.rb`](../demo/config/initializers/sentry.rb) —
the demo's worker boots with `server?` false, so `Wurk.configure_server` never
runs there. The policy lives in the demo app
([`demo/lib/demo_sentry_policy.rb`](../demo/lib/demo_sentry_policy.rb)), not in
the gem: the gem ships the integration, the demo decides what it is allowed to
send.

**Dropped events.** Three rules, and nothing else:

1. `BrokenJob` and `FlakyWebhookJob` — both fail on purpose so the Dead and
   Retries pages are never empty, so their events would bury every real error
   under a steady stream of intended ones.
2. Soak-tagged events: a tag key or value of `soak` marks an event to drop.
   Demo soak payloads use `demo-soak`; the middleware bridge sets the scoped
   Sentry tag to `demo-soak=soak` so this existing policy recognizes it.
3. Everything else is sent.

The job-class list is exactly those two. Other demo failures that are by-design
are not on it — the nightly export chunk fails a slice of its runs on purpose —
so those still report.

**Scrubbed material.** Everything that is sent has its sensitive parts removed
first. Request headers and cookies lose any entry whose name or whose value
looks like a credential — an `Authorization` or `Cookie` header, an API key, a
bearer token, a session cookie — while ordinary headers and cookies survive. A
header or cookie field in any shape but a Hash — a serialized cookie String,
as a raw request env arrives — has no entries to scrub, so nothing in it can
be vouched for: a populated one drops the whole event. Job arguments lose any
argument whose key looks like a credential, or whose value looks like a
credential or like personal data (an email address); ordinary arguments
survive. An event that cannot be scrubbed is dropped rather than sent: the
demo fails closed.

## ✅ Infra requirements

All live as of 2026-07-21 — the stack is at
`../infrastructure/stacks/apps/wurk-demo/`. Kept as a checklist because it is
also the rebuild recipe. Items marked **(app)** live in this repo.

- [x] **(app)** Containerized demo (`Dockerfile`, `bin/demo-entrypoint`) — web + worker roles.
- [x] **(app)** Gated deploy workflow (`deploy-demo.yml`).
- [x] **(app)** Read-only dashboard (`WURK_WEB_READ_ONLY=1`) + live data generator.
- [x] **Redis** — a small managed/in-cluster Redis (7.x) reachable from both pods, exposed as `REDIS_URL`. Demo data only; safe to flush.
- [x] **`SECRET_KEY_BASE`** — a strong random value injected at runtime (k8s secret) so the Rails app boots in production. Not baked into the image.
- [x] **Registry pull access** — a sealed `docr-pull` imagePullSecret in ns `wurk-demo`.
- [x] **ArgoCD Application `wurk-demo`** in `../infrastructure` — Deployments for `web` (cmd `web`) and `worker` (cmd `worker`), a Service, and the Redis dependency.
- [x] **ArgoCD Image Updater** watching `registry.digitalocean.com/developerz-ai/wurk-demo` with `update-strategy: newest-build` and `allow-tags: regexp:^sha-[0-9a-f]{7}$` so a pushed image auto-syncs. The `sha-<7>` tag format is the contract — if CI stops emitting it, Image Updater silently has no candidate and the demo freezes on its current digest (this happened, and is what #418 fixes). CI holds no cluster credentials, so there are no `ARGOCD_*` secrets.
- [x] **DNS** — `wurk.demo.developerz.ai` → the cluster ingress / Traefik.
- [x] **Ingress (Traefik) + TLS** — route the host to the `web` Service, Let's Encrypt cert.
- [x] **Public rate-limit** — a Traefik rate-limit middleware on the ingress to discourage abuse.
- [x] **Hourly reset `CronJob`** — [`cronjob-reset.yml`](https://github.com/developerz-ai/infrastructure/blob/main/stacks/apps/wurk-demo/manifests/cronjob-reset.yml) in the infrastructure repo (`demo:reset` → FLUSHDB) so queue latency doesn't creep up over hours. Without it the demo stays alive but the `high`/`low` queues accumulate a multi-hour backlog.
- [x] **Resource limits + restart policy** — modest CPU/mem requests; pods must recover on restart with no manual step (the generator self-heals; no persistent state outside Redis).

### Settled decisions

- **Redis sizing / persistence:** ephemeral, no persistence — an in-cluster
  Dragonfly (`manifests/dragonfly.yml`). A restart just empties it and the
  generator refills within a tick, which is also what the hourly reset relies on.
