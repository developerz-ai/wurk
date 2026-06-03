-- Bucket limiter: increment counter for the current epoch slot.
-- Timing comes from redis-cli TIME (the caller reads it with a TIME command, so
-- the counter boundary tracks the Redis clock and is immune to client skew —
-- sidekiq-ent.md §1), and the resolved epoch key is passed in KEYS[1]. Computing
-- the key caller-side keeps it a SINGLE declared key, so the script is safe on
-- Redis Cluster (no CROSSSLOT) and Dragonfly (no undeclared-key access) alike —
-- the old script built lmtr-b:<name>:<epoch> from a bare prefix inside Lua, which
-- both reject (#91). No system clock is read inside Lua.
-- KEYS[1] = lmtr-b:<name>:<epoch>
-- ARGV[1] = limit (max count per epoch)
-- ARGV[2] = used (units to charge; 1 by default)
-- ARGV[3] = ttl seconds
-- ARGV[4] = seconds to next boundary (returned verbatim for the caller's sleep)
-- Returns {acquired, current, seconds_to_next_boundary}.
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local used = tonumber(ARGV[2])
local ttl = tonumber(ARGV[3])
local remaining = tonumber(ARGV[4])
local current = tonumber(redis.call('GET', key) or '0')
if current + used <= limit then
  current = redis.call('INCRBY', key, used)
  redis.call('EXPIRE', key, ttl)
  return {1, current, remaining}
end
return {0, current, remaining}
