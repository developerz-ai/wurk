-- Concurrent limiter: release a held slot. ZREM returns 0 when the slot
-- was already reclaimed by the acquire path's ZREMRANGEBYSCORE — caller
-- treats that as an "overage" and bumps the metric on the Ruby side.
-- KEYS[1] = lmtr-cs:<name>
-- ARGV[1] = slot_id
-- Returns 1 if removed, 0 if already reclaimed.
return redis.call('ZREM', KEYS[1], ARGV[1])
