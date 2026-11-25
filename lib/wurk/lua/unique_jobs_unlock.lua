-- sidekiq-unique-jobs 8.x unlock.lua. Returns the jid when this job held the
-- lock (or the lock was orphaned), nil while another holder keeps it. The "1"
-- pushed to QUEUED wakes a job blocked on the lock. Every key is in KEYS.
-- KEYS = [digest, queued, primed, locked, info, changelog, digests, expiring_digests]
-- ARGV = [jid, pttl, lock_type, limit, lock_score, now, max_history, script_name, sync_locked, run]
-- `run` is Wurk's: the token of the run unlocking (see unique_jobs_claim.lua), empty
-- when the unlock is the jid's. A lock marked by another run of the jid is left whole.
local digest, queued, primed, locked, info, changelog, digests = KEYS[1], KEYS[2], KEYS[3], KEYS[4], KEYS[5], KEYS[6], KEYS[7]
local job_id, lock_type, limit = ARGV[1], ARGV[3], tonumber(ARGV[4])
local now, max_history, script_name, sync_locked = tonumber(ARGV[6]), tonumber(ARGV[7]), ARGV[8], ARGV[9] == "1"
local run = ARGV[10] or ""

-- A value that is another run's mark (fifteen decimals, UniqueJobs::Run.token). Any
-- other value says only that the jid holds the lock: one the gem or an older Wurk
-- wrote, or a snapshot put back.
local function another_runs(holder)
  local decimals = string.match(holder, "^%d+%.(%d+)$")
  return #run > 0 and holder ~= run and decimals and #decimals == 15
end

local function log(message, prev_jid)
  if not max_history or max_history == 0 then return end
  local entry = cjson.encode({digest = digest, job_id = job_id, script = script_name, message = message, time = now, prev_jid = prev_jid})
  redis.call("ZADD", changelog, now, entry)
  redis.call("ZREMRANGEBYRANK", changelog, 0, -1 * max_history)
  redis.call("PUBLISH", changelog, entry)
end

if sync_locked and limit <= 1 then
  if lock_type ~= "until_expired" then
    redis.call("UNLINK", digest, info, locked, primed)
  end
  redis.call("ZREM", digests, digest)
  log("Unlocked")
  return job_id
end

local holder = redis.call("HGET", locked, job_id)
local holds_lock = holder and true or false
if holder and another_runs(holder) then
  log("Superseded by a later run")
  return nil
end
if not holds_lock then
  -- A run that held the lock left the line when it took it: an entry of its jid
  -- there now is a later run's.
  if #run == 0 then
    redis.call("LREM", queued, -1, job_id)
    redis.call("LREM", primed, -1, job_id)
  end
  local others = redis.call("LLEN", queued) + redis.call("LLEN", primed) + redis.call("HLEN", locked)
  if others > 0 then
    log("Yielding to other lock holders")
    return nil
  end
end

if lock_type ~= "until_expired" then
  redis.call("HDEL", locked, job_id)
  if limit and limit > 1 then
    local locked_count = redis.call("HLEN", locked)
    redis.call("UNLINK", digest, info)
    if locked_count < 1 then
      redis.call("UNLINK", locked, primed)
      redis.call("ZREM", digests, digest)
    elseif redis.call("LLEN", primed) == 0 then
      redis.call("UNLINK", primed)
    end
  else
    redis.call("UNLINK", digest, info, locked, primed)
    redis.call("ZREM", digests, digest)
  end
else
  redis.call("ZREM", digests, digest)
end

redis.call("LPUSH", queued, "1")
redis.call("PEXPIRE", queued, 5000)

log("Unlocked")
return job_id
