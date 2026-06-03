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
is enough; the generator re-seeds within one tick.

```text
            ┌── web (puma)  ──► read-only dashboard + generator ──┐
internet ──►│                                                     ├──► Redis
            └── worker (swarm) ──► drains jobs ───────────────────┘
```

## Deploy: who can trigger it

`.github/workflows/deploy-demo.yml` **builds and pushes the image only** — it
holds no cluster credentials. The in-cluster **ArgoCD Image Updater** watches the
GHCR `:latest` digest and syncs the deployment automatically; the pushed digest
*is* the deploy trigger. The workflow is **manual only** (`workflow_dispatch`) and
gated three ways so only the org can ship an image:

1. **Public repo + `workflow_dispatch`** → only users with *write* access (org
   members) can trigger it; external forks cannot.
2. **`DEMO_DEPLOYERS` repo variable** (comma-separated GitHub usernames) → the
   `authorize` job rejects anyone not listed.
3. **Protected `demo` environment** → add Required Reviewers. The gate sits on the
   `build` job (not a separate deploy job) because the digest push is what
   triggers the deploy, so approval must pause the run *before* the image ships.

### One-time GitHub setup (repo admin)

- **Settings → Secrets and variables → Actions → Variables:** add
  `DEMO_DEPLOYERS` = e.g. `sebyx07,din-handle,ivann-handle`.
- **Settings → Environments → `demo`:** create it, add the deployer(s) as
  *Required reviewers*, and (optionally) restrict the deployment branch to `main`.

No `ARGOCD_*` secrets are needed — CI never talks to the cluster. The image push
uses the built-in `GITHUB_TOKEN` (GHCR), so no registry secret is required either.

## ✅ Infra requirements (for the infra team)

What's needed to make `https://wurk.demo.developerz.ai` go live. Items marked
**(app)** are in this repo / done; the rest are infra.

- [x] **(app)** Containerized demo (`Dockerfile`, `bin/demo-entrypoint`) — web + worker roles. *Build still needs one verification pass.*
- [x] **(app)** Gated deploy workflow (`deploy-demo.yml`).
- [x] **(app)** Read-only dashboard (`WURK_WEB_READ_ONLY=1`) + live data generator.
- [ ] **Redis** — a small managed/in-cluster Redis (7.x) reachable from both pods, exposed as `REDIS_URL`. Demo data only; safe to flush.
- [ ] **`SECRET_KEY_BASE`** — a strong random value injected at runtime (k8s secret) so the Rails app boots in production. Not baked into the image.
- [ ] **GHCR pull access** — an `imagePullSecret` (or public package) so the cluster can pull `ghcr.io/developerz-ai/wurk-demo`.
- [ ] **ArgoCD Application `wurk-demo`** in `../infrastructure` — Deployments for `web` (cmd `web`) and `worker` (cmd `worker`), a Service, and the Redis dependency.
- [ ] **ArgoCD Image Updater** watching `ghcr.io/developerz-ai/wurk-demo:latest` (digest strategy) so a pushed image auto-syncs. CI holds no cluster credentials, so there are no `ARGOCD_*` secrets.
- [ ] **DNS** — `wurk.demo.developerz.ai` → the cluster ingress / Traefik.
- [ ] **Ingress (Traefik) + TLS** — route the host to the `web` Service, Let's Encrypt cert.
- [ ] **Public rate-limit** — a Traefik rate-limit middleware on the ingress to discourage abuse.
- [ ] **Resource limits + restart policy** — modest CPU/mem requests; pods must recover on restart with no manual step (the generator self-heals; no persistent state outside Redis).

### Decisions to confirm with infra

- **Redis sizing / persistence:** demo can run on an ephemeral Redis (a restart
  just empties it; the generator refills). Confirm whether infra wants
  persistence at all.
