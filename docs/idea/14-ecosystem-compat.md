# Ecosystem Compatibility

Drop-in for Sidekiq is not just the Sidekiq gem itself. A 100% drop-in claim means the **Sidekiq ecosystem** of third-party gems built on top of Sidekiq's API also works unchanged against Wurk.

This is testable, and it's the strongest possible proof of compat.

## Status today

| Gem | Upstream suite runs against Wurk in CI? |
|---|---|
| sidekiq-cron | **Yes** — on PRs that change a filtered path (the workflow is path-gated), in the [`ecosystem` job](../../.github/workflows/ecosystem.yml), pinned in [`test/ecosystem/sidekiq-cron/PIN`](../../test/ecosystem/sidekiq-cron/PIN) |
| sidekiq-unique-jobs | **Yes**, same job, pinned in [`PIN`](../../test/ecosystem/sidekiq-unique-jobs/PIN). Leaves out the one spec file that needs a Toxiproxy service. |
| sidekiq-failures | **Yes**, same job, pinned in [`PIN`](../../test/ecosystem/sidekiq-failures/PIN). Leaves out the test for upstream's ERB home page under a bare Rack `Sidekiq::Web`, adds `Sec-Fetch-Site` to the suite's requests, and uses a [test-only adapter](../../test/ecosystem/sidekiq-failures/adapter.rb) for one assertion on Processor internals. |
| sentry-sidekiq | **Yes**, same job, pinned in [`PIN`](../../test/ecosystem/sentry-sidekiq/PIN). A [test-only adapter](../../test/ecosystem/sentry-sidekiq/adapter.rb) covers the suite's reach into a private ivar. |
| every other gem below | **No**, untested on Wurk in CI. The pin and blocker for sidekiq-status are recorded [further down](#not-yet-in-the-matrix--pin-researched-blocker-known). opentelemetry-instrumentation-sidekiq and rspec-sidekiq were measured by hand and are not in the job: the first needs a password-protected Redis and asserts `BRPOP`, the second's failing matchers assume stock's Enterprise and ActiveJob internals. |

Each gem in the job also runs a [`boot_check.rb`](../../test/ecosystem/boot_check_support.rb): the gem loaded into the real `sidekiq` and `wurkswarm` executables, with the swarm preload on and off and with fake testing mode switched on at load. A gem's suite passing does not prove the gem runs. sidekiq-cron's suite stayed green while Wurk's Launcher overwrote the `@cron_poller` the gem's prepend had just set, so no cron job ever fired in a real server: the suite never boots a Launcher. `test/ecosystem/sidekiq-cron/boot_check.rb` starts the real `sidekiq` executable with the gem loaded and asserts ticks. Any gem that hooks process lifecycle needs a check like it.

Keeping any add-on gem needs the git-only [`sidekiq` shim gem](../../ecosystem/sidekiq-shim/README.md), because every one of them declares `add_dependency "sidekiq"`. A user keeping an untested gem should prove it in staging before production. The native replacements Wurk ships (periodic loops, `unique_for:`, `track:`, rate limiters) are the supported path, and the migration guide documents how to move live sidekiq-cron schedules and sidekiq-unique-jobs locks across a cutover ([`docs/migrate-from-sidekiq.md` §6](../migrate-from-sidekiq.md#6-third-party-gem-mappings)).

## What we aim to test against

The gems below are widely used and depend on Sidekiq's public surface in ways that exercise different parts of the API. If they work, Wurk is genuinely drop-in. This is the target matrix, not the current one — see [Status today](#status-today).

| Gem | What it exercises |
|---|---|
| sidekiq-cron | Periodic jobs built on Sidekiq scheduler — uses Sidekiq::Worker, scheduler enqueue, Web UI extension hooks |
| sidekiq-unique-jobs | Unique-job middleware — exercises client and server middleware chains, sidekiq_options |
| sidekiq-scheduler | Alternative scheduler — exercises Sidekiq.configure_server, internal API |
| sidekiq-status | Job status tracking — middleware chains, Sidekiq::Worker hooks |
| sidekiq-failures | Failure tracker — Sidekiq::Failures hook, Web UI extension |
| sidekiq-throttled | Throttling middleware — server middleware, fetcher hooks |
| sidekiq-batch (the OSS one) | Batches without paying Pro — Redis key schema |
| activejob-uniqueness | ActiveJob layer uniqueness — verifies the ActiveJob adapter shape |
| sidekiq-pro-like gems / sidekiq-grouping | Bulk patterns — client middleware, Redis bulk ops |

This list grows over time. New ecosystem gems are added when they demonstrate Wurk is missing a Sidekiq behavior.

## How we test

A dedicated CI job runs each ecosystem gem's own test suite **against Wurk** instead of Sidekiq. Mechanism:

- A small wrapper sets up a bundle with the ecosystem gem and points it at Wurk via the same require alias trick that makes Wurk drop-in for end users.
- The wrapper runs the gem's published test suite.
- The job passes only if the suite passes unchanged.

If a gem's suite fails, the failure is the spec — we either fix Wurk to match Sidekiq's behavior the gem relies on, or document the divergence as an intentional incompatibility (rare and a last resort).

A harness is added to `test/ecosystem/` only when it is green. `test:ecosystem` is not a required merge check (the live required set belongs to the `main-protection` ruleset) — it runs on PRs that touch a filtered path and reports there, but it never gates a merge. A permanently red suite would still train everyone to ignore the signal, so until the gap is closed the pin and the exact blocker live here instead.

## Not yet in the matrix — pin researched, blocker known

### sidekiq-status

**Pin:** `kenaniah/sidekiq-status` v4.0.0 (`af8e633d5771901f5ef4eedafe7a239a2209b115`). Not `utgarda/sidekiq-status`: that repo is archived, its last release (v1.1.4, 2019) drives Sidekiq-5 APIs Sidekiq 7 removed (`Sidekiq.options`, `Sidekiq::RedisConnection.create`, `Sidekiq::CLI.instance.run`), and it fails against real modern Sidekiq too — so it cannot be an oracle for Wurk. Development moved to the fork, whose gemspec pins `sidekiq >= 7, < 9`: exactly the release the shim gem reports. Its Rakefile aliases `task :test => :spec`, so the harness's plain `rake test` works.

**Blocker:** `lib/sidekiq-status/web.rb` mutates `Sidekiq::WebHelpers::SAFE_QPARAMS` at load, and its `web_spec.rb` drives `Sidekiq::Web` through rack-test expecting ERB-rendered HTML. Wurk's dashboard is a precompiled SPA plus a JSON API (`docs/idea/08-dashboard.md`) and exposes a deliberate subset of the helper surface as `Wurk::Web::Extension::Helpers`, not `Sidekiq::WebHelpers`. Closing this is a Web-surface decision, not a shim: land it with the job-status slice that needs the suite.

Already closed by this work: `require "sidekiq/processor"`, `"sidekiq/manager"` and `"sidekiq/job_retry"` — all three are real upstream files this suite requires, and all three now resolve (`lib/sidekiq/`, pinned by `test/unit/sidekiq_entrypoint_test.rb`).

## sidekiq-unique-jobs

In the job since this harness landed, pinned at v8.1.0. The suite hardcodes `localhost:6379`, DB 0, and flushes it before every example, so [`prepare`](../../test/ecosystem/sidekiq-unique-jobs/prepare) points every connection at the harness's DB. Its `rake rspec` task names darwin-only formatters, so [`COMMAND`](../../test/ecosystem/sidekiq-unique-jobs/COMMAND) runs upstream CI's own command. Leaves out `spec/integration/until_and_while_executing_spec.rb`, which needs a Toxiproxy service. `lib/wurk/job_set.rb` and `lib/wurk/sorted_entry.rb` carry the two behaviours this gem depends on and that used to lose jobs.

## Behaviour a gem's suite can't pin

sidekiq-cron 2.3.1's web suite sets `c[:csrf] = false` and POSTs with no `Sec-Fetch-Site`, and 9 of its tests fail on Wurk for that. Stock 8.1.5 answers those same requests with 403 when probed from outside, so Wurk keeps the gate: the pinned 2.4.0 is green, and a browser on plain HTTP sends no such header, so that posture would open real CSRF.

## Why this matters

- It's the most credible "100% drop-in" claim possible — verified against real third-party consumers.
- It catches subtle API drift that pure self-tests would miss (private-ish methods third parties came to depend on).
- It surfaces decisions: when a third-party gem relies on Sidekiq internals, we either expose those internals as a public Wurk API or deprecate the dependence with the gem's author.

## Tracking

Planned, not built: a status page on the docs site listing every gem in the matrix, its current pass/fail state, and the Wurk version it last passed against. Until it exists, [Status today](#status-today) above and `test/ecosystem/` are the record.
