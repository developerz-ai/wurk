-- Wurk only: give a hand-off list left without a TTL the hand-off TTL, in one
-- step with the checks that it is still a list and still has no TTL, so a key
-- that changed between the reaper's scan and this call is left as it is.
-- KEYS = [primed]
-- ARGV = [ttl_ms]
local primed = KEYS[1]
if redis.call("TYPE", primed).ok ~= "list" or redis.call("PTTL", primed) ~= -1 then
  return 0
end
return redis.call("PEXPIRE", primed, tonumber(ARGV[1]))
