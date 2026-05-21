-- Points limiter: post-call adjust. `delta` is signed — positive refunds
-- unused estimate, negative records an under-estimate. Clamped to [0, cap].
-- KEYS[1] = lmtr-p:<name>
-- ARGV[1] = delta (float)
-- ARGV[2] = cap
-- ARGV[3] = ttl
-- Returns the new points balance.
local key = KEYS[1]
local delta = tonumber(ARGV[1])
local cap = tonumber(ARGV[2])
local ttl = tonumber(ARGV[3])
local current = tonumber(redis.call('HGET', key, 'points') or '0')
local new_val = current + delta
if new_val < 0 then new_val = 0 end
if new_val > cap then new_val = cap end
redis.call('HSET', key, 'points', tostring(new_val))
redis.call('EXPIRE', key, ttl)
return tostring(new_val)
