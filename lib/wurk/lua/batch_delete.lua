-- Pro Batch (§2.5 `Status#delete`): remove a batch and every reference to
-- it in one atomic step — its own keys, both index ZSETs, its tag indexes,
-- and its membership in the parent's `-kids` and `-pkids`. A child left in
-- the parent's `-pkids` would block the parent's callbacks forever, so the
-- parent's drain state comes back like BATCH_KID_DONE's.
-- KEYS = [<own keys> (ARGV[2] of them), batches, dead-batches,
--         (b-<parent>, b-<parent>-jids, b-<parent>-pkids, b-<parent>-kids when ARGV[3] == "1"),
--         tags:<tag>, ...]
-- ARGV = [bid, own key count, has parent ("1"/"0")]
-- Returns the parent's [pending, live_jids, pending_kids]; live = -1 when
-- there is no parent to re-evaluate.
local n = tonumber(ARGV[2])
redis.call("unlink", unpack(KEYS, 1, n))
redis.call("zrem", KEYS[n + 1], ARGV[1])
redis.call("zrem", KEYS[n + 2], ARGV[1])
local result = { 0, -1, -1 }
local first_tag = n + 3
if ARGV[3] == "1" then
  local p = n + 3
  redis.call("srem", KEYS[p + 3], ARGV[1])
  redis.call("srem", KEYS[p + 2], ARGV[1])
  if redis.call("exists", KEYS[p]) == 1 then
    result = { tonumber(redis.call("hget", KEYS[p], "pending")) or 0,
               redis.call("scard", KEYS[p + 1]), redis.call("scard", KEYS[p + 2]) }
  end
  first_tag = p + 4
end
for i = first_tag, #KEYS do
  redis.call("srem", KEYS[i], ARGV[1])
end
return result
