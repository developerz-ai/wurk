-- Pro Batch: record a job that failed and will retry (transient failure).
-- SADDs the jid to the `failed` set and bumps `failures` only on the first
-- add, so `failures` == SCARD(b-<bid>-failed) == the number of jobs
-- currently in a failing/retrying state. Re-failures of the same jid are
-- idempotent. Cleared by BATCH_ACK_SUCCESS (retry passed) or
-- BATCH_ACK_COMPLETE (job died). Spec §2.5, §2.8.
--
-- `b-<bid>-failed` is born here, so it carries the same NX expiry stamp as
-- BATCH_PUSH.
-- KEYS = [b-<bid>, b-<bid>-failed]
-- ARGV = [jid, expiry_seconds]
-- Returns 1.
if redis.call("sadd", KEYS[2], ARGV[1]) == 1 then
  redis.call("hincrby", KEYS[1], "failures", 1)
end
redis.call("expire", KEYS[1], ARGV[2], "NX")
redis.call("expire", KEYS[2], ARGV[2], "NX")
return 1
