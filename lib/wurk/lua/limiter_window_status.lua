-- Window limiter: read-only probe — entries inside the window plus the oldest
-- score still in it, in one atomic round trip.
-- Deliberately does NOT trim: ZREMRANGEBYSCORE lives exclusively in
-- limiter_window_acquire.lua. `size`/`status` are introspection the dashboard
-- runs on every GET, from a host whose clock Wurk does not control; the old
-- Ruby-side read trimmed against that client clock, so a host running more than
-- one interval ahead of Redis wiped a live window on a mere read and let the
-- next callers charge the limit a second time.
-- Timing comes from redis TIME, the same invariant limiter_bucket_acquire.lua
-- documents: the window boundary tracks the Redis clock, never the caller's.
-- The cutoff is inclusive to mirror exactly what the acquire trim retains
-- (it removes [-inf, cutoff), so a score of exactly cutoff is still in window).
-- KEYS[1] = lmtr-w:<name>
-- ARGV[1] = interval seconds (float ok)
-- Returns {count_in_window, oldest_in_window_score_or_-1}.
local key = KEYS[1]
local t = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
local cutoff = tostring(now - tonumber(ARGV[1]))
local current = redis.call('ZCOUNT', key, cutoff, '+inf')
local oldest = redis.call('ZRANGEBYSCORE', key, cutoff, '+inf', 'WITHSCORES', 'LIMIT', 0, 1)
return {current, oldest[2] or '-1'}
