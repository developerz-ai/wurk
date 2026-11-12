# Compatibility and divergences

The question this page answers: **will my exact setup work?**

Wurk reproduces Sidekiq's public interface — the same Redis key schema, the same job JSON, the same sorted-set score formats, and every public `Wurk::*` class exposed under its `Sidekiq::*` name. Existing jobs and existing Redis data keep working on a one-line `Gemfile` swap; a live move is a drain cutover, except that a stock Sidekiq 8 app (no Pro, no Enterprise) may roll with both fleets live, under the conditions in the [migration guide](https://github.com/developerz-ai/wurk/blob/main/docs/migrate-from-sidekiq.md#rolling-cutover-stock-sidekiq-8-only).

Behind that interface the runtime is Wurk's own. A small number of behaviours therefore differ **deliberately**, and this page lists the ones you can observe from your application.

## Divergences you can observe

| Area | What Wurk does instead | Why it matters to you |
|---|---|---|
| **Fetch** | Reliable `BLMOVE` fetch is the *only* mode; `Sidekiq::BasicFetch` is aliased to it | No `BRPOP` at-most-once mode. A `SIGKILL`ed worker's in-flight jobs are reclaimed, not lost |
| **Rate limiters** | A job that exhausts its reschedule budget (default 20) goes to the dead set tagged `rate_limited` | Sidekiq Enterprise re-raises into the normal 25× retry cycle. Wurk stops there — check the dead set, not the retry set |
| **Ack timing** | The `LREM` retiring a finished job rides the *next* fetch's pipeline | Widens the window in which a hard kill re-runs an already-finished job. Same at-least-once contract, wider window — jobs must be idempotent |
| **Paused queues** | The `paused` set is read from a 2s-TTL per-fetcher cache | A pause can take up to ~2s to stop a busy worker. Reporting APIs and the dashboard read Redis directly |
| **Rolling restarts** | `SIGUSR1` is driven by the swarm parent itself | No einhorn or external process manager to integrate |
| **`SIGTSTP`** | One-way quiet: workers stop fetching, in-flight continues | There is **no resume**. Send `SIGTERM` to shut down |
| **Opt-in job-JSON keys** | `traceparent`/`tracestate` (telemetry), `track` (job status), `timeout`/`deadline`/`deadline_at` | Only written when you opt in; inert cargo to a stock Sidekiq consumer reading the same queue |

Each entry above has a full write-up — what the spec says, why the divergence is safe, and the code anchor — in [docs/idea/parity-divergences.md](https://github.com/developerz-ai/wurk/blob/main/docs/idea/parity-divergences.md).

## Third-party gems

Ecosystem gems are the strongest drop-in proof available. Four of them run their own upstream suite against Wurk in CI, through the git-only `sidekiq` shim gem (`bin/rake test:ecosystem`; the `ecosystem` workflow runs on PRs that touch a filtered path):

- **Green in CI:** `sidekiq-cron`, `sidekiq-unique-jobs` (less the one spec file that needs Toxiproxy), `sidekiq-failures` (less upstream's ERB home-page test) and `sentry-sidekiq`. Each also boots in the real `sidekiq` and `wurkswarm` executables. Pins and exclusions: `test/ecosystem/README.md`.
- **Pinned with a known blocker, not yet in CI:** `sidekiq-status`. The rest of the target matrix (`sidekiq-scheduler`, `sidekiq-throttled`, …) is untested. A harness lands only once it is green, because a permanently red check trains everyone to ignore CI.

The pins and the exact blocker for each are in [docs/idea/14-ecosystem-compat.md](https://github.com/developerz-ai/wurk/blob/main/docs/idea/14-ecosystem-compat.md). Treat any gem not in that green list as "expected to work, not yet proven by its own suite" — test it against your setup before cutting over.

Wurk also ships its own equivalents of several of these (unique jobs, periodic jobs, job status), so a gem you were using for a Pro/Enterprise gap may simply be removable.

## Platforms

Ruby `>= 3.2.0`, Redis `>= 7.0.0`. Without `fork` (JRuby, TruffleRuby, Windows; untested in CI) only the single-process `wurk` runner and `config.wurk.embed_in_web` apply: `wurkswarm` and the railtie's swarm have no fallback.

## Parity testing

`test/parity/` holds independently written oracles asserting what Sidekiq's documented surface promises. **When Wurk disagrees with an oracle, Wurk is wrong** unless the divergence is recorded as intentional. `.sidekiq_sha` pins the upstream commit whose documented behaviour those oracles target.

## Legal basis

Wurk is an independent reimplementation of a published interface — not a clean room, and it does not claim to be one. Nothing is derived from the closed source of Sidekiq Pro or Enterprise. "Sidekiq" is a trademark of Contributed Systems, LLC; Wurk is not affiliated with, sponsored by, or endorsed by them.

Full statement, including the *Google v. Oracle* reasoning and the licence position: **[docs/compatibility.md](https://github.com/developerz-ai/wurk/blob/main/docs/compatibility.md)**.
