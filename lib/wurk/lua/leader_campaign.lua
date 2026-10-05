-- Ent leader campaign (sidekiq-ent.md §6): win the cluster lock, or refresh
-- it when this process already holds it.
--
-- One server-side step because the refresh is a compare-and-expire. As two
-- commands (GET, then EXPIRE) our lock can lapse and a follower win it in
-- between, and the bare EXPIRE then extends *its* lock while we go on
-- believing we lead.
--
-- KEYS = [dear-leader]
-- ARGV = [<host>:<pid>:<nonce>, ttl_seconds]
-- Returns 1 when this process holds the lock afterwards, 0 otherwise.
if redis.call("set", KEYS[1], ARGV[1], "NX", "EX", ARGV[2]) then
  return 1
end
if redis.call("get", KEYS[1]) == ARGV[1] then
  redis.call("expire", KEYS[1], ARGV[2])
  return 1
end
return 0
