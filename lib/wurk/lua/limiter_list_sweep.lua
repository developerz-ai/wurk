-- Limiter list sweep: drop `lmtr-list` members whose metadata HASH is gone.
-- KEYS[1]   = lmtr-list
-- KEYS[2..] = lmtr:<name>, one per candidate, aligned with ARGV
-- ARGV[1..] = candidate names, already probed as dead by the caller
-- Returns the number of names removed.
--
-- Membership carries no TTL of its own while `lmtr:<name>` expires with the
-- limiter's ttl, so every interpolated name leaves a permanent entry behind and
-- the SET grows forever. Names are the only thing stored here, so the sweep has
-- to ask the metadata key whether each one is still real.
--
-- Re-checking EXISTS is the point of doing this in a script: the caller's probe
-- and this call are separate round trips, and limiter_register.lua only SADDs on
-- the *first* metadata write, so dropping a name that re-registered in between
-- would hide a live limiter until its ttl ran out. Deciding again inside the
-- atomic step makes both orderings safe: register-then-sweep keeps the name,
-- sweep-then-register re-adds it.
--
-- Every metadata key arrives through KEYS (Redis Cluster and Dragonfly refuse
-- one built inside Lua). The caller batches the candidates: Lua is atomic and
-- single-threaded in Redis, so sweeping a set that leaked for months in one
-- call would block every other client for the whole pass.
local removed = 0
for i = 1, #ARGV do
  if redis.call('EXISTS', KEYS[i + 1]) == 0 then
    removed = removed + redis.call('SREM', KEYS[1], ARGV[i])
  end
end
return removed
