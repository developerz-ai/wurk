-- Concurrent limiter: atomic slot acquire.
-- KEYS[1] = lmtr-cs:<name>     ZSET of held slot ids, score = expiry epoch.
-- KEYS[2] = lmtr-stats:<name>  HASH of metric counters.
-- ARGV[1] = limit
-- ARGV[2] = lock_timeout seconds
-- ARGV[3] = slot_id (caller-generated; SHA-fingerprinted on the Ruby side)
-- ARGV[4] = ttl seconds
-- Returns {acquired, held, reclaimed}. acquired: 1 if slot recorded, 0 if full.
-- held: live ZCARD gauge after this pass. reclaimed: expired slots evicted here.
-- The lifetime `held` counter in the stats hash is bumped here, not on the Ruby
-- side, so it stays atomic with the ZADD (a process dying mid-acquire can't
-- undercount) and costs no extra round trip on the acquire path.
local cs_key = KEYS[1]
local st_key = KEYS[2]
local t = redis.call('TIME')
local now = tonumber(t[1])
local limit = tonumber(ARGV[1])
local lock_to = tonumber(ARGV[2])
local slot_id = ARGV[3]
local ttl = tonumber(ARGV[4])
local reclaimed = redis.call('ZREMRANGEBYSCORE', cs_key, '-inf', '(' .. now)
if reclaimed > 0 then
  redis.call('HINCRBY', st_key, 'reclaimed', reclaimed)
end
local held = redis.call('ZCARD', cs_key)
if held < limit then
  redis.call('ZADD', cs_key, now + lock_to, slot_id)
  redis.call('HINCRBY', st_key, 'held', 1)
  redis.call('EXPIRE', cs_key, ttl)
  redis.call('EXPIRE', st_key, ttl)
  return {1, held + 1, reclaimed}
end
return {0, held, reclaimed}
