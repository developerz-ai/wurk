-- Pro Batch: a child batch finished — drop it from the parent's pending
-- children and report the parent's drain state in the same call, so two
-- sibling children finishing at once cannot both read an empty `pkids`
-- (the SREM-then-SCARD round trips they used to make let both fire the
-- parent).
--
-- When the SREM empties the parent (no live jids, no pending children, hash
-- still alive) the parent's bid goes into the fire index (KEYS[4]) in the
-- same atomic step — the parent-drain-via-kid_done case `batch_ack_success`
-- never sees. Keeps the parent's fire recoverable like the other two
-- drain-observing scripts.
-- KEYS = [b-<parent>, b-<parent>-jids, b-<parent>-pkids, fire index]
-- ARGV = [child bid, drain epoch, parent bid]
-- Returns [pending, live_jids, pending_kids] for the parent.
redis.call("srem", KEYS[3], ARGV[1])
if redis.call("exists", KEYS[1]) == 0 then
  return { 0, -1, -1 }
end
local pending = tonumber(redis.call("hget", KEYS[1], "pending")) or 0
local live = redis.call("scard", KEYS[2])
local kids = redis.call("scard", KEYS[3])
if live == 0 and kids == 0 then
  redis.call("zadd", KEYS[4], ARGV[2], ARGV[3])
end
return { pending, live, kids }
