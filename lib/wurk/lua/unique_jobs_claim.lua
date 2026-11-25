-- Wurk only: a run enters the lock its jid already holds (taken at push, or left
-- by a run that crashed or is still unwinding) and becomes its holder: the value
-- beside the jid is from now on this run's, so an earlier run of the same jid can
-- neither unlock nor renew it. Takes nothing: a jid that is not in LOCKED gets 0
-- and no key is written. Every key is in KEYS.
-- KEYS = [digest, queued, primed, locked, info, changelog, digests, expiring_digests]
-- ARGV = [jid, run]
local locked, job_id, run = KEYS[4], ARGV[1], ARGV[2]

if redis.call("HEXISTS", locked, job_id) == 0 then
  return 0
end

redis.call("HSET", locked, job_id, run)
return 1
