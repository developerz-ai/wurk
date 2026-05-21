-- Window limiter: sliding window via ZSET of timestamps.
-- Sliding from the first use, not from a fixed epoch boundary. Each call
-- trims entries older than (now - interval) and counts what remains; if
-- under limit, ZADDs `used` entries with scores at now and unique member
-- ids (microsecond + counter suffix to allow multi-add in one TIME tick).
-- KEYS[1] = lmtr-w:<name>
-- ARGV[1] = limit
-- ARGV[2] = interval seconds (float ok)
-- ARGV[3] = used
-- ARGV[4] = ttl
-- ARGV[5] = nonce (Ruby-side random; isolates parallel callers)
-- Returns {acquired, current_size, oldest_score_in_window_or_-1}.
local key = KEYS[1]
local t = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
local interval = tonumber(ARGV[2])
local limit = tonumber(ARGV[1])
local used = tonumber(ARGV[3])
local ttl = tonumber(ARGV[4])
local nonce = ARGV[5]
redis.call('ZREMRANGEBYSCORE', key, '-inf', '(' .. (now - interval))
local current = redis.call('ZCARD', key)
if current + used <= limit then
  for i = 1, used do
    redis.call('ZADD', key, now, now .. ':' .. nonce .. ':' .. i)
  end
  redis.call('EXPIRE', key, ttl)
  return {1, current + used, -1}
end
local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
local oldest_score = -1
if oldest[2] then
  oldest_score = tonumber(oldest[2])
end
return {0, current, tostring(oldest_score)}
