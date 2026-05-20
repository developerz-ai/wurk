# Overview

## What

A Ruby background job processor implementing the complete public API of Sidekiq OSS + Sidekiq Pro + Sidekiq Enterprise. Wire-compatible: same Redis keys, same job JSON, same Ruby DSL.

Not "Sidekiq-compatible enough." Bit-for-bit on the public surface.

## The value prop (one sentence)

**100% API-compatible with Sidekiq + Pro + Enterprise, free forever, and meaningfully faster.**

That's the entire pitch. Every other claim in this project supports one of those three.

## The three pillars (must all be true)

1. **100% drop-in.** Swap one gem line. Existing jobs, batches, limiters, cron entries, Redis data — all continue to work untouched. Third-party gems built on Sidekiq's API (sidekiq-cron, sidekiq-unique-jobs, sidekiq-scheduler, sidekiq-status, etc.) work against Wurk with no changes. We test this in CI — see 14-ecosystem-compat.md.
2. **Free.** Pro features (batches, reliable fetch, queue pause, statsd, search). Enterprise features (rate limiters, cron, unique jobs, encryption, historical metrics, swarm, rolling restart, leader election). No license fees, ever.
3. **Faster and optimized.** Real multi-process parallelism. Optimized Redis path with BLMOVE, Lua bulk ops, pipelining. Per-fork connection pools. Hot-path allocations minimized. Faster than stock Sidekiq on enqueue, fetch, and total throughput. CI enforces this — regressions block merge. See 06-performance.md.

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
