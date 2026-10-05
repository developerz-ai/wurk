-- Pro Batch: register a scheduled (`at`) job into a batch AND ZADD it onto
-- the `schedule` set, atomically. This is the deferred sibling of BATCH_PUSH:
-- same SADD-guarded total/pending counting, but the enqueue action is a ZADD
-- (schedule for later) instead of an LPUSH (queue now). A `perform_in` inside
-- `batch.jobs` must move `total`/`pending` at *creation* — otherwise the
-- empty-marker check (batch.rb) sees no counter movement and fires
-- `:complete`/`:success` while real jobs still sit in `schedule`.
--
-- No died / dead-batches handling (unlike BATCH_PUSH): a job scheduled at
-- creation time is always new to the batch. When the scheduler later promotes
-- it, the re-push routes through BATCH_PUSH, whose guard finds the jid already
-- live (SADD == 0) → pure LPUSH, no recount. So registration happens exactly
-- once, here, at enqueue.
--
-- The other path that can create `b-<bid>-jids`, so it carries the same NX
-- expiry stamp as BATCH_PUSH.
-- KEYS = [schedule, b-<bid>, b-<bid>-jids]
-- ARGV = [at_score, job_json, jid, expiry_seconds]
-- Returns 1.
if redis.call("sadd", KEYS[3], ARGV[3]) == 1 then
  redis.call("hincrby", KEYS[2], "total", 1)
  redis.call("hincrby", KEYS[2], "pending", 1)
end
redis.call("expire", KEYS[2], ARGV[4], "NX")
redis.call("expire", KEYS[3], ARGV[4], "NX")
redis.call("zadd", KEYS[1], ARGV[1], ARGV[2])
return 1
