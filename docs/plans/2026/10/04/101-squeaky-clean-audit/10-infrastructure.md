# 10 — Infrastructure (`../infrastructure`) + demo

> Part of [`overview.md`](overview.md). Depends on: none. **Infra items are edited from the `developerz-ai/infrastructure` repo, not here** (read its `CLAUDE.md`). Wurk-side items edited here. Source: infra audit 2026-10-04 (no kubectl on audit box; demo verified externally: `/wurk` 200, 6 processes, v1.7.6).

## Inventory (infra repo)

| Path | Purpose |
|---|---|
| `stacks/apps/wurk-demo/application.yml` | ArgoCD app + Image Updater (DOCR, newest-build, `^sha-[0-9a-f]{7}$`) |
| `stacks/apps/wurk-demo/manifests/deployment-{web,worker}.yml` | puma (probes `/wurk`) / swarm (no probe, intentional) |
| `…/manifests/cronjob-reset.yml` | hourly `rails demo:reset` (FLUSHDB) |
| `…/manifests/dragonfly.yml` | in-namespace Redis, no persistence (#1470 exception) |
| `…/manifests/{configmap,sealed-secret,sealed-secret-docr-pull,ghcr-pull-secret,service,ingressroute,certificate,namespace,kustomization}.yml` | config, creds, routing |
| `stacks/platform/observability/blackbox-exporter/manifests/probe.yml:87` | uptime probe |
| `.github/workflows/wurk-runner-health{,-deadman}.yml` + `scripts/{ci,lib/ci}/runner-health*.ts`, `workflow-freshness.ts` | queued-job watchdog + deadman |
| `bin/vm/ci-runner-setup.sh`, `scripts/vm/ci-runner.ts`, `scripts/lib/virt/ci-runner.ts`, `scripts/vm/vm-hosts.yml:341+` | ci-1/ci-2 self-hosted runners |
| `docs/ci/self-hosted-runners.md`, `docs/off-platform-hosts.md:368+` | runner security model |

## Wurk-repo fixes (here)

| ID | Sev | Where | Defect | Fix |
|---|---|---|---|---|
| I1 | Med | `bin/demo-entrypoint:28` + `demo/config/initializers/wurk.rb` (DemoProducer starts `if ENV["WURK_DISABLED"]=="1"`) | Worker role + reset CronJob also set `WURK_DISABLED=1` → 2nd producer thread in the swarm **parent, which then forks** (violates "never share a socket across forks"); producer `trap(INT/TERM)` can clobber swarm handlers; doubled load. | Gate producer on explicit `WURK_DEMO_PRODUCER=1` set only by web branch of entrypoint; no `trap` in producer. |
| I2 | Low | `docs/demo-deploy.md:17` | Says worker runs w/ `WURK_DISABLED` unset → railtie; reality: `=1` + `Swarm#supervise` direct. | Correct row. |
| I3 | Low | `demo/k8s/demo-reset-cronjob.yaml`; `docs/demo-deploy.md:24,101` | Reference manifest diverged (ghcr pull secret, `REDIS_URL` secret key, 120s deadline) — following doc breaks reset. | Delete file; point doc at infra manifest. |
| I4 | Low | `.github/workflows/deploy-demo.yml:57-62` | GHCR mirror justified by literal `ghcr.io` ref that kustomize always rewrites → dead weight. | Drop mirror + prune step, or label rollback-only. |
| I5 | Low | demo swarm sizes from node's 6 cores vs pod 100m CPU (563MiB RSS / 768Mi limit) | Same root as R9 in [`09`](09-production-readiness.md). | Fixed by R9 cgroup detection; meanwhile pin `WURK_COUNT` in demo config. |
| I6 | Med (doc truth) | `CLAUDE.md:100` | (a) "Bench no longer sits on fixed 8vcpu SKU" — `WURK_BENCH_RUNNER=blacksmith-8vcpu-ubuntu-2404` live. (b) "fork PR pinned … must never reach self-hosted" overclaims: pin is in fork-controlled YAML; real control = `approval_policy: all_external_contributors` on persistent runners. | Reword both to truth; cite approval policy + infra#1285 as real hardening. |
| I7 | Low | #502 app half | `SENTRY_DSN` injected, no Sentry gem in `demo/Gemfile`. | `sentry-ruby`/`sentry-rails` gated by `WURK_DEMO_REPORT_ERRORS`; `before_send` drops `BrokenJob`/`FlakyWebhookJob`. (Demo files owned by Din — coordinate.) |
| I8 | Low | #482 | demo lock | [`06`](06-release-lane.md). |

## Infra-repo fixes (from `../infrastructure`)

| ID | Sev | Where | Defect | Fix |
|---|---|---|---|---|
| X1 | High | `.github/workflows/wurk-runner-health.yml:38` | Cron */15 → actually ~5 runs/day, gaps 3–8.5h; stuck wurk job unseen for hours. | Move watchdog to k8s CronJob or hv-1 systemd timer. File issue (none exists). |
| X2 | High | `wurk-runner-health-deadman.yml`, `scripts/lib/ci/runner-health-deadman.ts:31-43` | 2h bound assumes 15m cadence; deadman itself ~4h; 5/12 recent runs `STALE` → #infra-alerts noise. | Same move as X1; interim: bound from measured cadence or documented acceptance. |
| X3 | Med | `manifests/kustomization.yml:20-22` (`newTag: latest`) + `imagePullPolicy: IfNotPresent` | Immutability assumption only holds via in-cluster Image Updater override; lose it → stale cached `:latest`. | Pin `sha-<7>`/digest baseline in git. |
| X4 | Low-Med sec | `manifests/ghcr-pull-secret.yml`, `kustomization.yml:10` | Unused; holds personal `read:packages` token. | Remove + revoke token (HITL revoke). Closes #800 wurk residual. |
| X5 | Low | `stacks/apps/wurk-demo/README.md:9,49-65`; `application.yml:8,22-26`; `deployment-web.yml:40-41`; `deployment-worker.yml:44-45` | GHCR-era text. | Rewrite for DOCR/newest-build/in-cluster writeback. |
| X6 | Low | root `README.md:47`, `stacks/platform/argocd-image-updater/README.md:15,38`, `docs/runbooks/registry-cleanup.md:45`, `registry-cleanup{,-on-deploy}.yml` | wurk-demo listed as GHCR app. | Reclassify DOCR; ensure DOCR prune keeps in-cluster-pinned `sha-<7>` (not visible to `pinned-digests.ts`). |
| X7 | Med | runner `ci-2-3` (`wurk-bench` label) idle since 2026-08-18, reachable via bare `self-hosted` | Decide bench home. | Either point `WURK_BENCH_RUNNER` at `wurk-bench` after variance measured, or record Blacksmith exception + deregister ci-2-3 (HITL). |
| X8 | P2 | ci-1/ci-2 run ≥2 runners per machine | Wurk suite oversubscribes (see [`05`](05-ci-gates.md) C11). | Set `NCPU` in each runner's `.env` = cores/runners/2. |
| X9 | Low | stale memory/handoffs: `wurk-demo-down-status.md`, `wurk-din-ownership.md` ("React/Vite" → SolidJS), `handoff/2026-08-18-wurk-ci-1259-northstar-completion/status.yml` (0% but 01–03 done), `handoff/2026-09-02-dz-config-consolidation/status.yml` slice 08 | Mislead future agents. | Update/close; #1546 (handoff audit) is the systemic fix. |

## Open infra issues touching wurk

| Issue | Closure |
|---|---|
| #1259 wurk CI → hv-1 epic | X7 decision; land/decouple #1318; refresh Children list; file X1/X2 follow-up; close. |
| #502 demo errors → GlitchTip | infra: `ensure-projects.ts` stop routing wurk-demo to `#errors`; app: I7; infra: `WURK_DEMO_REPORT_ERRORS=1`; live test (1 web error arrives, 15m zero job events). |
| #800 registry policy (wurk residual) | Premise stale; X4 + X5/X6; close or narrow to db-mcp-gateway (#907). |
| #1318 remove Blacksmith deadman | Delete `blacksmith-usage-deadman/`; separate PRs for `BlacksmithUsageDeadManUnverified` rule + r2-env refs. HITL. |
| #1285 JIT runners | HITL decisions (dedicated vs widened GH App; orchestrator host). Real fix for I6(b). |
| #681 / #1388 Blacksmith cost / no meter | Clears via X7. |
| #1466 Dragonfly consolidation | No wurk action (permanent exception). |

## Done when
- I1–I7 merged here; X1–X9 merged in infra; #1259, #502, #800 closed; #1318/#1285/X7 decisions recorded.
