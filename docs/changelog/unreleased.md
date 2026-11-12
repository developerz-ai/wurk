# Unreleased

### Added

- **More `/metrics` families:**
  - child restarts by reason (`wurk_swarm_child_restarts_total{reason}`) and the crash streak (`wurk_swarm_crash_streak`);
  - Redis round-trip time;
  - pool checkout timeouts and free slots;
  - poison kills, reclaims by source and leader changes;
  - scheduler promotions and lag;
  - outage-buffer drops;
  - the oldest running job;
  - per-child PSS;
  - per-class duration histograms (the 20 busiest classes plus `other`).

  Every family is listed in `docs/metrics.md`. The restart counters live in the swarm parent's memory and add no Redis key.
- **`wurk health --max-job-age SECONDS`** fails the probe when a job has run longer than that.
- **`config.metrics_retention=`** sets how long the 10-minute metrics buckets are kept. It changes the TTL only, has a 3-day floor, and the default stays 30 days.
- Ops examples: `examples/capistrano/wurk.rake`, plus `StartLimit*` settings in `examples/wurk.service`. `docs/deployment.md` gains a sizing table, and `RELEASE.md` sets an "Upgrade notes" convention for release notes.

### Changed

- **`reliable_push` outage replay** sends 100 jobs per push instead of one (250 buffered jobs: 250 pushes → 3).
- The heartbeat info JSON is built once per process, byte-identical to before.
- The statsd `queue.size` gauge is sent by the leader only.
