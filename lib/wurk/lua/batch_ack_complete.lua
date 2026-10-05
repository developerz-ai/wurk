-- Pro Batch: ACK a job that exhausted retries and died. Moves the jid from
-- "currently failing" to "died": SREMs from the failed set (decrementing
-- `failures` if it was recorded as failing), SADDs to died, and SREMs from
-- live jids so the batch can fire `:complete` even with terminally failed
-- jobs. `b-<bid>-failed` holds only currently-retrying jids; `b-<bid>-died`
-- holds terminally-dead ones (spec §2.8 — the two sets are distinct).
--
-- `b-<bid>-died` is born here, so it carries the same NX expiry stamp as
-- BATCH_PUSH.
-- KEYS = [b-<bid>, b-<bid>-jids, b-<bid>-died, b-<bid>-failed, b-<bid>-pkids]
-- ARGV = [jid, expiry_seconds]
-- Returns [live_jids, died_count, first_death, pending_kids, pending].
-- `first_death` is 1 the first time *any* jid is SADDed into the died set,
-- 0 thereafter — caller uses it to fire `:death` exactly once per batch.
local was_pre_existing_death = redis.call("scard", KEYS[3])
redis.call("srem", KEYS[2], ARGV[1])
if redis.call("srem", KEYS[4], ARGV[1]) == 1 then
  redis.call("hincrby", KEYS[1], "failures", -1)
end
local died_added = redis.call("sadd", KEYS[3], ARGV[1])
redis.call("expire", KEYS[1], ARGV[2], "NX")
redis.call("expire", KEYS[3], ARGV[2], "NX")
local first_death = 0
if was_pre_existing_death == 0 and died_added == 1 then
  first_death = 1
end
return { redis.call("scard", KEYS[2]), redis.call("scard", KEYS[3]), first_death,
         redis.call("scard", KEYS[5]), tonumber(redis.call("hget", KEYS[1], "pending")) or 0 }
