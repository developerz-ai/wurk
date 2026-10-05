-- Pro Batch: a child batch finished — drop it from the parent's pending
-- children and report the parent's drain state in the same call, so two
-- sibling children finishing at once cannot both read an empty `pkids`
-- (the SREM-then-SCARD round trips they used to make let both fire the
-- parent).
-- KEYS = [b-<parent>, b-<parent>-jids, b-<parent>-pkids]
-- ARGV = [child bid]
-- Returns [pending, live_jids, pending_kids] for the parent.
redis.call("srem", KEYS[3], ARGV[1])
if redis.call("exists", KEYS[1]) == 0 then
  return { 0, -1, -1 }
end
return { tonumber(redis.call("hget", KEYS[1], "pending")) or 0,
         redis.call("scard", KEYS[2]), redis.call("scard", KEYS[3]) }
