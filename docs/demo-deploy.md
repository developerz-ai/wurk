# Demo deployment (wurk.demo.developerz.ai)

The public demo is the `test/dummy` Rails app — it mounts the Wurk dashboard and
runs the [#33 workload generator](../test/dummy/app/workloads/demo/workload.rb)
so every widget shows live, churning data. The dashboard runs **read-only**
(`WURK_WEB_READ_ONLY=1`): every mutating endpoint returns 403 at the middleware
layer, not just hidden in JS.

## Architecture

One image (`Dockerfile`), two roles via `bin/demo-entrypoint`:

| Role | Process | Notes |
|---|---|---|
| `web` | puma serving the read-only dashboard **+** the workload generator | `WURK_DISABLED=1` keeps the swarm out of this process (a Redis-holding thread must never be forked). |
| `worker` | the Wurk swarm that drains the generated jobs | `WURK_DISABLED` unset → the railtie boots it. |

Both connect to Redis via `REDIS_URL`. A reset/seed (the generator self-heals on
a Redis flush) keeps the demo from ever looking dead — a flush of the demo Redis
is enough; the generator re-seeds within one tick.

```
            ┌── web (puma)  ──► read-only dashboard + generator ──┐
internet ──►│                                                     ├──► Redis
            └── worker (swarm) ──► drains jobs ───────────────────┘
```

## Deploy: who can trigger it

`.github/workflows/deploy-demo.yml` is **manual only** (`workflow_dispatch`) and
gated three ways so only the org can deploy:

1. **Public repo + `workflow_dispatch`** → only users with *write* access (org
   members) can trigger it; external forks cannot.
2. **`DEMO_DEPLOYERS` repo variable** (comma-separated GitHub usernames) → the
   `authorize` job rejects anyone not listed.
3. **Protected `demo` environment** → add Required Reviewers so a deploy waits
   for a named approver.

### One-time GitHub setup (repo admin)

- **Settings → Secrets and variables → Actions → Variables:** add
  `DEMO_DEPLOYERS` = e.g. `sebyx07,din-handle,ivann-handle`.
- **Settings → Environments → `demo`:** create it, add the deployer(s) as
  *Required reviewers*, and (optionally) restrict the deployment branch to `main`.
- **Secrets** (Environment or repo): `ARGOCD_SERVER`, `ARGOCD_AUTH_TOKEN`
  (see below). The image push uses the built-in `GITHUB_TOKEN` (GHCR) — no extra
  registry secret needed.

The deploy step does ArgoCD `app set image.tag` + `app sync`. If infra prefers
ArgoCD Image Updater or a manifest bump in `../infrastructure`, swap that one
step — the gating above is independent of the deploy mechanism.

## ✅ Infra requirements (for the infra team)

What's needed to make `https://wurk.demo.developerz.ai` go live. Items marked
**(app)** are in this repo / done; the rest are infra.

- [x] **(app)** Containerized demo (`Dockerfile`, `bin/demo-entrypoint`) — web + worker roles. *Build still needs one verification pass.*
- [x] **(app)** Gated deploy workflow (`deploy-demo.yml`).
- [x] **(app)** Read-only dashboard (`WURK_WEB_READ_ONLY=1`) + live data generator.
- [ ] **Redis** — a small managed/in-cluster Redis (7.x) reachable from both pods, exposed as `REDIS_URL`. Demo data only; safe to flush.
- [ ] **GHCR pull access** — an `imagePullSecret` (or public package) so the cluster can pull `ghcr.io/developerz-ai/wurk-demo`.
- [ ] **ArgoCD Application `wurk-demo`** in `../infrastructure` — Deployments for `web` (cmd `web`) and `worker` (cmd `worker`), a Service, and the Redis dependency. Parameterize `image.tag` so the deploy step can set it.
- [ ] **ArgoCD API access for CI** — `ARGOCD_SERVER` (host) + `ARGOCD_AUTH_TOKEN` (a deploy-scoped account/token that can `sync` only `wurk-demo`), added as GitHub secrets.
- [ ] **DNS** — `wurk.demo.developerz.ai` → the cluster ingress / Traefik.
- [ ] **Ingress (Traefik) + TLS** — route the host to the `web` Service, Let's Encrypt cert.
- [ ] **Public rate-limit** — a Traefik rate-limit middleware on the ingress to discourage abuse.
- [ ] **Resource limits + restart policy** — modest CPU/mem requests; pods must recover on restart with no manual step (the generator self-heals; no persistent state outside Redis).

### Decisions to confirm with infra

- **Deploy mechanism:** ArgoCD `app sync` from CI (current scaffold) vs. ArgoCD
  Image Updater (no CI deploy step) vs. image-tag bump committed to
  `../infrastructure`. This determines which secrets the workflow needs.
- **Redis sizing / persistence:** demo can run on an ephemeral Redis (a restart
  just empties it; the generator refills). Confirm whether infra wants
  persistence at all.
