-- Pro Batch (§2.2 `#remove_jobs`): drop jids from the batch. `total` and
-- `pending` move by exactly the number of jids actually removed (so a
-- repeated call is a no-op), and a removed jid that was mid-retry leaves
-- `failures` too. Reports the drain state: removing the last live jid is
-- a drain like any ack.
-- KEYS = [b-<bid>, b-<bid>-jids, b-<bid>-failed, b-<bid>-pkids]
-- ARGV = [jid, ...]
-- Returns [removed, pending, live_jids, pending_kids].
local removed = 0
local exists = redis.call("exists", KEYS[1]) == 1
for i = 1, #ARGV do
  if redis.call("srem", KEYS[2], ARGV[i]) == 1 then
    removed = removed + 1
    if redis.call("srem", KEYS[3], ARGV[i]) == 1 and exists then
      redis.call("hincrby", KEYS[1], "failures", -1)
    end
  end
end
if not exists then
  return { removed, 0, -1, -1 }
end
local pending
if removed > 0 then
  redis.call("hincrby", KEYS[1], "total", -removed)
  pending = redis.call("hincrby", KEYS[1], "pending", -removed)
else
  pending = tonumber(redis.call("hget", KEYS[1], "pending")) or 0
end
return { removed, pending, redis.call("scard", KEYS[2]), redis.call("scard", KEYS[4]) }
