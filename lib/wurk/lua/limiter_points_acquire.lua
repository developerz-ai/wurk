-- Points limiter: token bucket with explicit `estimate` charge per call.
-- Refill = refill_per_sec * elapsed, capped at the initial cap. If the
-- (refilled) balance is < estimate, OverLimit immediately — no sleep
-- loop (spec §1.4: points raises immediately when empty). On success
-- the caller may refund/over-charge via limiter_points_refund.lua.
-- KEYS[1] = lmtr-p:<name>
-- ARGV[1] = initial_points (cap)
-- ARGV[2] = refill_per_sec
-- ARGV[3] = estimate
-- ARGV[4] = ttl
-- Returns {acquired, points_after_charge_or_balance}.
local key = KEYS[1]
local t = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
local cap = tonumber(ARGV[1])
local refill = tonumber(ARGV[2])
local estimate = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])
local data = redis.call('HMGET', key, 'points', 'last')
local points = tonumber(data[1] or cap)
local last = tonumber(data[2] or now)
local elapsed = now - last
if elapsed < 0 then elapsed = 0 end
local refilled = points + (elapsed * refill)
if refilled > cap then refilled = cap end
if refilled >= estimate then
  local remaining = refilled - estimate
  redis.call('HSET', key, 'points', tostring(remaining), 'last', tostring(now))
  redis.call('EXPIRE', key, ttl)
  return {1, tostring(remaining)}
end
redis.call('HSET', key, 'points', tostring(refilled), 'last', tostring(now))
redis.call('EXPIRE', key, ttl)
return {0, tostring(refilled)}
