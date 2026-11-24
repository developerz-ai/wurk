# Unreleased

### Added

- **`wurk_jobs_dead_total{queue,class}`: a death counter the dead set's cap cannot hide.** The dead set is capped at `dead_max_jobs` (10,000 by default), so once full every kill evicts the oldest entry and `wurk_dead_size` stops moving: an alert on its `delta` can never fire on a busy cluster. Every move to the dead set (retries exhausted, `:kill`, an API or dashboard kill, a poison pill, a payload the processor or scheduler cannot run) now also increments the `stat:deaths` hash, one field per queue and class (an ActiveJob's wrapped class), and `/metrics` exports it as a cluster-wide counter. New pairs past 500 fold into `queue="other",class="other"`; a kill written past `maxmemory` is not counted. The example `PrometheusRule` replaces `WurkDeadSetGrowing` with `WurkJobsDying` (`increase(wurk_jobs_dead_total[1h]) > 10` per queue and class) and `WurkDeadSetAtCap` ([metrics](../metrics.md#operational-gauges-on-the-health-listener)).
