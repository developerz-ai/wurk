# Overview

## What

A Ruby background job processor implementing the complete public API of Sidekiq OSS + Sidekiq Pro + Sidekiq Enterprise. Wire-compatible: same Redis keys, same job JSON, same Ruby DSL.

Not "Sidekiq-compatible enough." Bit-for-bit on the public surface.

## The value prop (one sentence)

**100% API-compatible with Sidekiq + Pro + Enterprise, free forever.**

That's the entire pitch. Every other claim in this project exists to support it — including the third pillar below, which is how the first two are kept honest rather than a selling point of its own.

## The three pillars (must all be true)

1. **100% drop-in.** Swap one gem line. Existing jobs, batches, limiters, cron entries, Redis data — all continue to work untouched. Third-party gems built on Sidekiq's API (sidekiq-cron, sidekiq-unique-jobs, sidekiq-scheduler, sidekiq-status, etc.) work against Wurk with no changes. We test this in CI — see 14-ecosystem-compat.md.
2. **Free.** Pro features (batches, reliable fetch, queue pause, statsd, search). Enterprise features (rate limiters, cron, unique jobs, encryption, historical metrics, swarm, rolling restart, leader election). No license fees, ever.
3. **Measured and optimized.** Real multi-process parallelism. Optimized Redis path with BLMOVE, Lua bulk ops, pipelining. Per-fork connection pools. Hot-path allocations minimized. Two benchmark suites, and only one of them gates: `rake bench` compares Wurk against its own past self and blocks merge on a >5% regression; `rake bench:vs_sidekiq` compares against stock Sidekiq and gates nothing, so a green CI says nothing about Sidekiq. Wurk is **not** currently faster than stock Sidekiq — roughly 0.87×–1.02× depending on workload shape and process configuration, with parity on CPU- and I/O-bound jobs and still behind on framework overhead (noop) and boot time. See 06-performance.md and `docs/benchmarks.md`.

## Who it's for

- Teams paying for Sidekiq Pro ($995/yr) and/or Enterprise ($3,000+/yr) who want $0.
- Rails apps that don't want a separate worker deployment — Wurk forks workers from the existing Rails process.
- Anyone hitting Sidekiq's throughput ceiling and ready to use real forks instead of just threads.

## Non-goals

- A new job DSL. We implement Sidekiq's.
- A different Redis schema. Wire-compat is the whole point.
- Replacing ActiveJob. We sit underneath it.

## "AOSP for Sidekiq"

Public API + behavioral spec, clean-room implementation. Legally defensible. Same end-user surface, independent code.

## Drop-in means

Every Sidekiq class name continues to work via aliases inside Wurk. Existing `include Sidekiq::Worker`, `Sidekiq::Batch.new`, `Sidekiq.configure_server`, `Sidekiq::Limiter.concurrent(...)` — all unchanged. Existing Redis data picked up on first boot. Third-party Sidekiq gems work without modification. Migration is: change gem name, restart.
