# 04 — Drop-in surface (executables · shim · routes · ecosystem pins)

> Part of [`overview.md`](overview.md). Depends on: [`01`](01-ci-green-doc-truth.md). Source: treasury surface inventory (sidekiq 7.3 + Pro + Ent, read-only) + adopter Gemfiles. 3 PRs (D1–D4 · D5–D8 · D9–D13).

Treasury verdict: almost everything it uses is supported. What blocks "one line": D1/D2 (executable + shim), [`03`](03-boot-guards-preflight.md) G11/G12, D5.

## Files to change
| ID | Where | Evidence | Change |
|---|---|---|---|
| D1 | `wurk.gemspec` `executables` (`wurk wurkswarm sidekiqswarm`); `ecosystem/sidekiq-shim/exe/sidekiq` | `bundle exec sidekiq -C …` = "command not found" after the swap unless the shim is bundled. Treasury k8s + Render both run it (`tesote/infrastructure/stacks/treasury/k8s/base/deployment-worker.yaml`, treasury `bin/sidekiq-start.sh`). README Install says "that's it". | Human call ([`13`](13-human-decisions.md) U3): ship `exe/sidekiq` in wurk (binstub clash if real sidekiq is also installed — [`03`](03-boot-guards-preflight.md) G2 covers that case) **or** document the rename in README Install + guide TL;DR. Default if undecided: document. |
| D2 | `README.md:308`, `docs/migrate-from-sidekiq.md:66,1169`, `docs/sentry.md:37`; `ecosystem/sidekiq-shim/sidekiq.gemspec:22-24` | Shim recipe `github: "developerz-ai/wurk", glob: …` floats on `main`; shim's `add_dependency 'wurk'` unconstrained → shim/wurk drift on `bundle update`. | Docs: add `tag: "v<version>"` (tags are `vX.Y.Z`, `tasks/release_helpers.rb:68`). Shim: `add_dependency 'wurk', "= #{version}"`. Unit test: shim pin == `Wurk::VERSION`; docs test: every shim recipe carries the current tag (bumped by the release rake task — add to `release:relock_demo`'s sibling steps). |
| D3 | `lib/generators/wurk/install/install_generator.rb` | Generator has no shim/Procfile step. | Detect gems in `Gemfile.lock` depending on `sidekiq` → print (not auto-edit) the pinned shim line; print the runner command for a found `Procfile`. Generator test. |
| D4 | `wurk.gemspec` | No post-install message. | Optional 3-line post-install: runner rename, shim, `wurk preflight`. |
| D5 | `lib/wurk/web/` Rack routes (follow existing extension routing in `lib/wurk/web/`); `docs/idea/parity-divergences.md:1093-1195` | Upstream `GET /stats`, `GET /stats/queues`, `HEAD /` missing → uptime checks + scripts against `/sidekiq/stats` break. | Add with Sidekiq's payload shape (`docs/target/sidekiq-free.md` §25.4). Remove the divergence entry. Parity oracle. |
| D6 | process title — `lib/wurk/launcher.rb` / `lib/wurk/swarm/child_boot.rb` (no `setproctitle` / `$0=` in `lib/` today) | Probes grep `ps` for `^sidekiq` (`tesote/coolify/scripts/coolify-api/sidekiq-health:72`); tesote.com + gringotts probes use `ps \| grep`. Sidekiq sets `sidekiq <ver> <tag> [x of y busy]`. | Set a proctitle per heartbeat matching the upstream format in `docs/target/sidekiq-free.md` (check the spec section; if absent, record as intentional divergence + document `wurk health`). Parent: `wurkswarm` title with child count. |
| D7 | `test/unit/` or `test/parity/` | SUPPORTED-BUT-UNTESTED surfaces treasury uses: `Sidekiq::Client.prepend` overriding `push_bulk` (path `lib/wurk/worker/setter.rb:74`); `Sidekiq::Queues.jobs_by_class` (`lib/wurk/queues.rb:30`); empty-string `SIDEKIQ_PRELOAD` (`lib/wurk/cli.rb:673-703`). | One test each. |
| D8 | `docs/migrate-from-sidekiq.md` §9 checklist | Cutover notes missing for: money-moving jobs + ACK-on-next-fetch window after SIGKILL (`docs/idea/parity-divergences.md:384`); poison kills reaching death handlers (Slack alert per kill in treasury); rollback `Queue#latency` ≈ −1.79e12 on wurk-written jobs vs latency alerts. | Three checklist rows, each linking its divergence entry. ACK-flush-per-queue option = human call U7. |
| D9 | `test/ecosystem/sidekiq-status/{PIN,Gemfile,COMMAND,boot_check.rb}` | Pinned (kenaniah v4.0.0), not in matrix; only blocker left = ERB `web_spec`. | Land like sidekiq-failures: exclude `spec/lib/sidekiq-status/web_spec.rb`. Update doc 14. |
| D10 | `test/ecosystem/` + `docs/idea/14-ecosystem-compat.md` | sidekiq-scheduler, sidekiq-throttled: no pin, no recorded blocker. Throttled patches fetch; `Sidekiq::BasicFetch` → `Wurk::Fetcher::Reliable` (`lib/wurk/compat.rb:121`), never measured. | Pin both, run once, record pass or exact blocker. No fix in this slice. |
| D11 | `test/ecosystem/` | Real-worker `boot_check.rb` exists per gem; aca53f6 class ("suite green because it never boots a Launcher") still open for unique-jobs retry/kill paths and failures set iteration. | Extend those two boot checks to assert end-to-end effect (retry lands, lock released on death; failure recorded + iterable). |
| D12 | `test/ecosystem/` matrix | Treasury/prod stacks untested: opentelemetry-instrumentation-sidekiq (prepends on `Processor#process_one`, `Launcher#heartbeat`, `Scheduled::Poller#enqueue`/`wait` — targets exist: `lib/wurk/processor.rb:114,254`, `launcher.rb:183`, `scheduled.rb:250,306,323`), rspec-sidekiq 5.x (smoke only), skylight (public API). sidekiq-cron tested at 2.4.0 only; apps run 2.3.1. | Add `boot_check.rb`-only legs (no upstream suite) for otel + skylight; rspec-sidekiq matcher subset suite; cron second pin 2.3.1 boot check. Record README-named blockers (password-Redis, `BRPOP`). |
| D13 | `docs/` new `migrate-from-activejob-backends.md` | No Solid Queue / GoodJob / Resque / DelayedJob story. | Short page: adapter swap, drain old backend, `recurring.yml` → `config.periodic`. |

## Steps
1. D5/D6 touch public Sidekiq surface → match `docs/target/` exactly; divergences go in `docs/idea/parity-divergences.md` with reason.
2. D9–D12: `test/ecosystem/README.md` conventions (pinned SHA clone, overlay Gemfile → `ecosystem/sidekiq-shim`). Own throwaway `redis-server`; never DB 0.
3. `tesote/sidekiq` (licensed Pro/Ent source) is reference-only on this machine: copy nothing into this repo.

## Tests
- `bin/rake test:parity` (D5), `bin/rake test:ecosystem` (D9–D12), `bin/check full`.
- D2: `bin/rake test TEST=test/unit/shim_pin_test.rb`.

## Done when
- A scratch Rails app with treasury's Gemfile plugin set + shim line resolves and `wurk boot-check` passes ([`03`](03-boot-guards-preflight.md) G10).
- `curl -I /wurk/` and `/wurk/stats` answer with upstream shapes.
- Doc 14 has a pin + status row for all 7 tracked gems.
