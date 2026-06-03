-- Bucket limiter: increment counter for current epoch slot.
-- All timing is from TIME (Redis-local clock) per spec — never Ruby's clock
-- inside Lua. Epoch = floor(now / interval), so counters reset at cardinal
-- boundaries of the interval unit (00 of minute/hour/day).
--
-- The epoch key (lmtr-b:<name>:<epoch>) must be DECLARED in KEYS[] — Redis
-- Cluster and Dragonfly reject a script that touches an undeclared key, and the
-- old script built the key inside Lua, which broke on Dragonfly (#91). The
-- caller can't know Redis's clock, so it passes the three candidate keys that
-- bracket its own epoch (base-1, base, base+1) and Lua picks the one matching
-- TIME. With NTP-sane skew Redis's epoch is always within ±1 of base, so one of
-- the three always matches; an out-of-range offset falls back to base (still a
-- declared key, never an undeclared-key error).
-- KEYS[1] = lmtr-b:<name>:<base-1>
-- KEYS[2] = lmtr-b:<name>:<base>     (caller's current epoch)
-- KEYS[3] = lmtr-b:<name>:<base+1>
-- ARGV[1] = limit (max count per epoch)
-- ARGV[2] = interval seconds
-- ARGV[3] = used (units to charge; 1 by default)
-- ARGV[4] = ttl seconds
-- ARGV[5] = base (the caller's epoch == KEYS[2])
-- Returns {acquired, current, seconds_to_next_boundary}.
local limit = tonumber(ARGV[1])
local interval = tonumber(ARGV[2])
local used = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])
local base = tonumber(ARGV[5])
local t = redis.call('TIME')
local now = tonumber(t[1])
local epoch = math.floor(now / interval)
local key = KEYS[(epoch - base) + 2] or KEYS[2]
local remaining = (epoch + 1) * interval - now
local current = tonumber(redis.call('GET', key) or '0')
if current + used <= limit then
  current = redis.call('INCRBY', key, used)
  redis.call('EXPIRE', key, ttl)
  return {1, current, remaining}
end
return {0, current, remaining}
