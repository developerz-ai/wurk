-- Bucket limiter: increment counter for current epoch slot.
-- All timing is from TIME (Redis-local clock) per spec — never Ruby's clock
-- inside Lua. Epoch = floor(now / interval), so counters reset at cardinal
-- boundaries of the interval unit (00 of minute/hour/day).
-- KEYS[1] = lmtr-b:<name>:<placeholder>  (suffixed with :<epoch> below)
-- ARGV[1] = limit (max count per epoch)
-- ARGV[2] = interval seconds
-- ARGV[3] = used (units to charge; 1 by default)
-- ARGV[4] = ttl seconds
-- Returns {acquired, current, seconds_to_next_boundary}.
local prefix = KEYS[1]
local t = redis.call('TIME')
local now = tonumber(t[1])
local interval = tonumber(ARGV[2])
local epoch = math.floor(now / interval)
local key = prefix .. ':' .. epoch
local limit = tonumber(ARGV[1])
local used = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])
local current = tonumber(redis.call('GET', key) or '0')
local remaining = (epoch + 1) * interval - now
if current + used <= limit then
  current = redis.call('INCRBY', key, used)
  redis.call('EXPIRE', key, ttl)
  return {1, current, remaining}
end
return {0, current, remaining}
