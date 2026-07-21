# Metrics history (time-series buckets)

The dashboard's **throughput** and **failures** charts read pre-aggregated,
cluster-total time-series buckets written by a leader-only rollup thread
(`Wurk::Metrics::Rollup`). This document covers the retention policy and the
resulting Redis footprint, which is **bounded entirely by TTL**.

## How it works

Every job execution already writes a per-class minute bucket
(`j|YYYYMMDD|H:M`, see `Wurk::Metrics::History`). Once per minute the elected
cluster leader sums the just-completed minute across all classes and folds the
total into three resolutions:

| Bucket key        | Resolution | Retention (TTL) | Serves window |
|-------------------|-----------:|----------------:|---------------|
| `jr\|1m\|<epoch>` | 1 minute   | 24 hours        | up to 24h     |
| `jr\|5m\|<epoch>` | 5 minutes  | 7 days          | up to 7d      |
| `jr\|1h\|<epoch>` | 1 hour     | 30 days         | up to 30d     |

`<epoch>` is the UTC start-of-bucket in integer seconds. Each bucket is a small
HASH with three integer fields: `p` (processed), `f` (failed), `ms` (total
runtime). Writes are idempotent `HSET` — the coarse buckets are recomputed from
their 1-minute children — so a missed tick, a leadership change, or a late
metric write converges to the same totals and never double-counts.

Only the leader writes (non-leader ticks return early), so N workers don't each
re-write the same buckets.

## Redis footprint (bounded)

At steady state the rollup keeps at most one live bucket per slot per retention
window:

| Bucket | Live keys at retention      | Count |
|--------|-----------------------------|------:|
| `jr\|1m` | 24h × 60                  | 1 440 |
| `jr\|5m` | 7d × 24 × 12              | 2 016 |
| `jr\|1h` | 30d × 24                 |   720 |
| **Total** |                          | **≈ 4 176** |

Each key is a 3-field integer HASH (tens of bytes), so the whole series costs on
the order of a few hundred KB regardless of throughput or cluster size. Idle
minutes write nothing (empty buckets are skipped), so a quiet cluster stores
even less. Nothing accumulates without bound: every key carries a TTL and is
reclaimed automatically.

## API

```text
GET /wurk/api/history/:bucket?window=24h
```

- `:bucket` — `1m`, `5m`, or `1h` (anything else → `400`).
- `?window=` — `s`/`m`/`h`/`d` suffix (e.g. `24h`, `7d`, `30d`); a bare number is
  seconds. Defaults to `24h`; clamped to the bucket's retention.

Returns a gap-filled array ready for the chart module (missing buckets read as
zero):

```json
{
  "bucket": "1m",
  "window": 86400,
  "series": [
    { "at": 1780000000, "processed": 1200, "failed": 7, "runtime_ms": 48000 }
  ]
}
```

## Gaps and self-healing

Each tick re-rolls the last `LOOKBACK_MINUTES` (15) completed source minutes,
idempotently. Because the source `j|…` minute buckets live `MID_TERM` (3 days),
a leadership failover or restart shorter than that window self-heals on the next
tick — the gap minutes are re-read from source and folded back into `jr|…`. Only
an outage **longer than the 15-minute lookback** leaves a hole, which then ages
out with the bucket's TTL (best-effort metrics).

History is not back-filled on a cold start (no prior `jr|…` data): a freshly
deployed cluster fills its charts in going forward over the retention window.
