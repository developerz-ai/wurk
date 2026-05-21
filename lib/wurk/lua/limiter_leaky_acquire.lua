-- Leaky bucket: drip = bucket_size / drain ops/sec, but exposed as
-- (bucket_size, drain_per_sec_float) — the Ruby caller pre-divides.
-- On each acquire: compute leaked = elapsed * drain_per_sec, decrement
-- level by that amount (floor 0), then if level+1 <= bucket_size add 1.
-- KEYS[1] = lmtr-l:<name>
-- ARGV[1] = bucket_size
-- ARGV[2] = drain_per_sec (float)
-- ARGV[3] = ttl
-- Returns {acquired, current_level_float}.
local key = KEYS[1]
local t = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
local bucket_size = tonumber(ARGV[1])
local drain = tonumber(ARGV[2])
local ttl = tonumber(ARGV[3])
local data = redis.call('HMGET', key, 'level', 'last')
local level = tonumber(data[1] or '0')
local last = tonumber(data[2] or now)
local elapsed = now - last
if elapsed < 0 then elapsed = 0 end
local new_level = level - (elapsed * drain)
if new_level < 0 then new_level = 0 end
if new_level + 1 <= bucket_size then
  new_level = new_level + 1
  redis.call('HSET', key, 'level', tostring(new_level), 'last', tostring(now))
  redis.call('EXPIRE', key, ttl)
  return {1, tostring(new_level)}
end
redis.call('HSET', key, 'level', tostring(new_level), 'last', tostring(now))
redis.call('EXPIRE', key, ttl)
return {0, tostring(new_level)}
