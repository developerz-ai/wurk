# Unreleased

### Changed

- **A job interrupted at the shutdown deadline is requeued after its thread has unwound, not before.** It was on its public queue, and running in another process, while its own `ensure` blocks were still releasing locks and limiter slots. The wait is at most 2s, inside the grace the swarm already allows; the payload stays in the private list meanwhile, so a SIGKILL loses nothing. A job that finishes or books a retry on its way out is no longer run again as well. A `config[:fetch_class]` fetcher that is not a `Fetcher::Reliable` keeps the old order ([reliability](../reliability.md#graceful-shutdown)).

### Fixed

- **sidekiq-unique-jobs, native: an interrupted run no longer releases the lock its own re-run holds.** The holder was known by jid, so when a requeued or reclaimed job ran again while its first run was still unwinding, that unwind deleted the lock and a third job ran beside the second; `refresh_lock!` told both runs they held it. Each run now marks the lock it enters (the time beside its jid in `:LOCKED`, so nothing new in Redis) and only the newest mark unlocks or renews, for `while_executing`, `until_executed` and `until_and_while_executing`; a job still re-enters the lock of a run that crashed. An unlock owed after a Redis outage is held to the same. Processes on Wurk 1.20 or the gem neither write nor check marks, so the deploy that brings this in still has the old exposure ([two runs of one job](../unique-jobs.md#two-runs-of-one-job-wurk-only)).
