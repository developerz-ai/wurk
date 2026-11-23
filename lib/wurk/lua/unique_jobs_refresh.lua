-- Wurk only: sidekiq-unique-jobs 8.x has no refresh. Pushes out the expiry of a
-- lock this jid still holds, re-applying from now what lock.lua and
-- queue_and_lock.lua set when the lock was taken. Takes nothing: a jid that is
-- not in LOCKED gets 0 and no key is written. Every key is in KEYS.
-- KEYS = [digest, queued, primed, locked, info, changelog, digests, expiring_digests]
-- ARGV = [jid, pttl, now]
-- Returns 1 when this jid holds the lock, 0 otherwise.
local digest, locked, info, expiring = KEYS[1], KEYS[4], KEYS[5], KEYS[8]
local job_id, pttl, now = ARGV[1], tonumber(ARGV[2]), tonumber(ARGV[3])

if redis.call("HEXISTS", locked, job_id) == 0 then
  return 0
end

if pttl > 0 then
  redis.call("PEXPIRE", digest, pttl)
  redis.call("PEXPIRE", locked, pttl)
  redis.call("PEXPIRE", info, pttl)
  -- An until_expired lock is also indexed by expiry, and the reaper deletes it
  -- once that score passes. Scored as lock.lua scores it (seconds plus
  -- milliseconds, the gem's arithmetic); XX leaves every other digest out.
  redis.call("ZADD", expiring, "XX", now + pttl, digest)
end

return 1
