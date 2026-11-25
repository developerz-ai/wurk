-- Wurk only: sidekiq-unique-jobs 8.x has no refresh. Pushes out the expiry of a
-- lock this jid still holds, re-applying from now what lock.lua and
-- queue_and_lock.lua set when the lock was taken. Takes nothing: a jid that is
-- not in LOCKED, or is there for a later run of it, gets 0 and no key is written.
-- Every key is in KEYS.
-- KEYS = [digest, queued, primed, locked, info, changelog, digests, expiring_digests]
-- ARGV = [jid, pttl, now, run]
-- `run` is the token of the run renewing (see unique_jobs_claim.lua), empty when
-- the caller is known by jid alone.
-- Returns 1 when the caller holds the lock, 0 otherwise.
local digest, locked, info, expiring = KEYS[1], KEYS[4], KEYS[5], KEYS[8]
local job_id, pttl, now, run = ARGV[1], tonumber(ARGV[2]), tonumber(ARGV[3]), ARGV[4]

-- A value that is another run's mark (fifteen decimals, UniqueJobs::Run.token). Any
-- other value says only that the jid holds the lock: one the gem or an older Wurk
-- wrote, or a snapshot put back.
local function another_runs(holder)
  local decimals = string.match(holder, "^%d+%.(%d+)$")
  return #run > 0 and holder ~= run and decimals and #decimals == 15
end

local holder = redis.call("HGET", locked, job_id)
if not holder or another_runs(holder) then
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
