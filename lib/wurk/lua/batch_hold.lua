-- Pro Batch: the hold a `#jobs` block keeps on its batch while it is open
-- (Batch#jobs). The hold is a sentinel member of the live jids set plus
-- one `pending`, so no ack can drain the batch before the block has pushed
-- everything; BATCH_ACK_SUCCESS releases it at block exit. SADD-guarded so
-- a block re-run under the same sentinel (a reclaimed job re-entering its
-- own batch) never counts twice. Stamps the same NX expiry as BATCH_PUSH,
-- since it can be the first writer of `b-<bid>-jids`.
-- KEYS = [b-<bid>, b-<bid>-jids]
-- ARGV = [sentinel, expiry_seconds]
-- Returns 1 when the hold was taken, 0 when it was already held.
local added = redis.call("sadd", KEYS[2], ARGV[1])
if added == 1 then
  redis.call("hincrby", KEYS[1], "pending", 1)
end
redis.call("expire", KEYS[1], ARGV[2], "NX")
redis.call("expire", KEYS[2], ARGV[2], "NX")
return added
