-- Concurrent limiter: release a held slot and book its metrics.
-- ZREM returns 0 when the slot was already reclaimed by the acquire path's
-- ZREMRANGEBYSCORE: the holder outran `lock_timeout`, counted as an overage.
-- KEYS[1] = lmtr-cs:<name>
-- KEYS[2] = lmtr-stats:<name>
-- ARGV[1] = slot_id
-- ARGV[2] = whole seconds the slot was held
-- ARGV[3] = ttl seconds
-- Returns 1 if removed, 0 if already reclaimed.
local removed = redis.call('ZREM', KEYS[1], ARGV[1])
if removed == 0 then
  redis.call('HINCRBY', KEYS[2], 'overages', 1)
end
redis.call('HINCRBY', KEYS[2], 'held_time', ARGV[2])
redis.call('EXPIRE', KEYS[2], ARGV[3])
return removed
