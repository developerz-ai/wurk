-- Limiter list sweep: drop `lmtr-list` members whose metadata HASH is gone.
-- KEYS[1]   = lmtr-list
-- ARGV[1]   = metadata key prefix ('lmtr:')
-- ARGV[2..] = candidate names, already probed as dead by the caller
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
-- The key is composed from an ARGV prefix (same shape as
-- reliable_schedule_promote's queue prefix) because the candidate list is
-- variable-length. The caller batches it: Lua is atomic and single-threaded in
-- Redis, so sweeping a set that leaked for months in one call would block every
-- other client for the whole pass.
local removed = 0
for i = 2, #ARGV do
  if redis.call('EXISTS', ARGV[1] .. ARGV[i]) == 0 then
    removed = removed + redis.call('SREM', KEYS[1], ARGV[i])
  end
end
return removed
