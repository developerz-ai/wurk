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
| `web` | puma serving the read-only dashboard **+** the workload generator | `WURK_DISABLED=1` keeps the swarm out of this process (a Redis-holding thread must never be forked). |
| `worker` | the Wurk swarm that drains the generated jobs | `WURK_DISABLED` unset → the railtie boots it. |

Both connect to Redis via `REDIS_URL`. A reset/seed (the generator self-heals on
a Redis flush) keeps the demo from ever looking dead — a flush of the demo Redis
is enough; the generator re-seeds within one tick. To stop queue latency from
creeping up over hours (the single worker can't drain everything the producer
tops up), an hourly `CronJob` flushes the demo Redis — reference manifest at
[`demo/k8s/demo-reset-cronjob.yaml`](../demo/k8s/demo-reset-cronjob.yaml), which
runs the `demo:reset` rake task.

```text
            ┌── web (puma)  ──► read-only dashboard + generator ──┐
internet ──►│                                                     ├──► Redis
            └── worker (swarm) ──► drains jobs ───────────────────┘
```

## Deploy: who can trigger it

`.github/workflows/deploy-demo.yml` **builds and pushes the image only** — it
holds no cluster credentials. The in-cluster **ArgoCD Image Updater** selects the
newest DOCR tag matching `^sha-[0-9a-f]{7}$` and syncs the deployment
automatically; the pushed digest
*is* the deploy trigger. It runs two ways — `workflow_dispatch` by hand, or
called by `release.yml` after it publishes the gem for a
`lib/wurk/version.rb` bump landing on `main` (the tag is an output there, cut
last; see [RELEASE.md](../RELEASE.md)) — and is gated three ways so only the
org can ship an image:

1. **Public repo + `workflow_dispatch`** → only users with *write* access (org
   members) can trigger it; external forks cannot.
2. **`DEMO_DEPLOYERS` repo variable** (comma-separated GitHub usernames) → the
   `authorize` job rejects anyone not listed. Guards the `workflow_dispatch`
   door only: a run called by `release.yml` passes `trusted: true`, which waives
   the allowlist (honoured only from the `release` workflow on `main`) — by then
   that caller has already published this commit's gem.
3. **Protected `demo` environment** → add Required Reviewers. The gate sits on the
   `build` job (not a separate deploy job) because the digest push is what
   triggers the deploy, so approval must pause the run *before* the image ships.

### One-time GitHub setup (repo admin)

- **Settings → Secrets and variables → Actions → Variables:** add
  `DEMO_DEPLOYERS` = e.g. `sebyx07,din-handle,ivann-handle`.
- **Settings → Environments → `demo`:** create it, add the deployer(s) as
  *Required reviewers*, and (optionally) restrict the deployment branch to `main`.

- **Settings → Environments → `demo` → Environment secrets:** add `DOCR_TOKEN`
  (a DigitalOcean token with registry write). It lives on the environment, not
  the repo, so only the reviewer-gated `build` job can read it — this repo is
  public.

No `ARGOCD_*` secrets are needed — CI never talks to the cluster.

### Registries

The image is pushed to **two** registries from one build:

| Registry | Tag | Role |
|---|---|---|
| `registry.digitalocean.com/developerz-ai/wurk-demo` | `sha-<7>` + `latest` + `<sha>` | **Deploy-critical.** Image Updater selects on `sha-<7>`; the other two are for humans and rollback. |
| `ghcr.io/developerz-ai/wurk-demo` | `sha-<7>` + `latest` + `<sha>` | Mirror, so the manifests' literal `ghcr.io` image ref still resolves. |

Infra moved the demo to DOCR on 2026-07-12 (infra #803) after a dead GHCR org
token broke fresh pulls; `stacks/apps/wurk-demo/manifests/kustomization.yml`
rewrites the `ghcr.io` name onto DOCR. **Pushing only to GHCR is a silent
no-op** — the build succeeds and the demo never changes.

## ✅ Infra requirements

All live as of 2026-07-21 — the stack is at
`../infrastructure/stacks/apps/wurk-demo/`. Kept as a checklist because it is
also the rebuild recipe. Items marked **(app)** live in this repo.

- [x] **(app)** Containerized demo (`Dockerfile`, `bin/demo-entrypoint`) — web + worker roles.
- [x] **(app)** Gated deploy workflow (`deploy-demo.yml`).
- [x] **(app)** Read-only dashboard (`WURK_WEB_READ_ONLY=1`) + live data generator.
- [x] **Redis** — a small managed/in-cluster Redis (7.x) reachable from both pods, exposed as `REDIS_URL`. Demo data only; safe to flush.
- [x] **`SECRET_KEY_BASE`** — a strong random value injected at runtime (k8s secret) so the Rails app boots in production. Not baked into the image.
- [x] **Registry pull access** — sealed `docr-pull` / `ghcr-pull` imagePullSecrets in ns `wurk-demo`.
- [x] **ArgoCD Application `wurk-demo`** in `../infrastructure` — Deployments for `web` (cmd `web`) and `worker` (cmd `worker`), a Service, and the Redis dependency.
- [x] **ArgoCD Image Updater** watching `registry.digitalocean.com/developerz-ai/wurk-demo` with `update-strategy: newest-build` and `allow-tags: regexp:^sha-[0-9a-f]{7}$` so a pushed image auto-syncs. The `sha-<7>` tag format is the contract — if CI stops emitting it, Image Updater silently has no candidate and the demo freezes on its current digest (this happened, and is what #418 fixes). CI holds no cluster credentials, so there are no `ARGOCD_*` secrets.
- [x] **DNS** — `wurk.demo.developerz.ai` → the cluster ingress / Traefik.
- [x] **Ingress (Traefik) + TLS** — route the host to the `web` Service, Let's Encrypt cert.
- [x] **Public rate-limit** — a Traefik rate-limit middleware on the ingress to discourage abuse.
- [x] **Hourly reset `CronJob`** — apply [`demo/k8s/demo-reset-cronjob.yaml`](../demo/k8s/demo-reset-cronjob.yaml) (`demo:reset` → FLUSHDB) so queue latency doesn't creep up over hours. Without it the demo stays alive but the `high`/`low` queues accumulate a multi-hour backlog.
- [x] **Resource limits + restart policy** — modest CPU/mem requests; pods must recover on restart with no manual step (the generator self-heals; no persistent state outside Redis).

### Settled decisions

- **Redis sizing / persistence:** ephemeral, no persistence — an in-cluster
  Dragonfly (`manifests/dragonfly.yml`). A restart just empties it and the
  generator refills within a tick, which is also what the hourly reset relies on.
