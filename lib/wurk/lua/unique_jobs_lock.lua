-- sidekiq-unique-jobs 8.x lock.lua: take the lock once the queued jid was primed
-- (the blocking path). Every key is in KEYS.
-- KEYS = [digest, queued, primed, locked, info, changelog, digests, expiring_digests]
-- ARGV = [jid, pttl, lock_type, limit, lock_score, now, max_history, script_name, run]
-- `run` is Wurk's: the token of the run taking the lock (see unique_jobs_claim.lua),
-- empty when a push takes it. The gem writes `now` in its place.
local digest, queued, primed, locked, info, changelog, digests, expiring = KEYS[1], KEYS[2], KEYS[3], KEYS[4], KEYS[5], KEYS[6], KEYS[7], KEYS[8]
local job_id, pttl, lock_type, limit, lock_score = ARGV[1], tonumber(ARGV[2]), ARGV[3], tonumber(ARGV[4]), ARGV[5]
local now, max_history, script_name = tonumber(ARGV[6]), tonumber(ARGV[7]), ARGV[8]
local run = ARGV[9] or ""

local function log(message, prev_jid)
  if not max_history or max_history == 0 then return end
  local entry = cjson.encode({digest = digest, job_id = job_id, script = script_name, message = message, time = now, prev_jid = prev_jid})
  redis.call("ZADD", changelog, now, entry)
  redis.call("ZREMRANGEBYRANK", changelog, 0, -1 * max_history)
  redis.call("PUBLISH", changelog, entry)
end

local function drop_queued()
  if limit <= 1 then
    redis.call("UNLINK", queued, primed)
  else
    redis.call("LREM", queued, -1, job_id)
    redis.call("LREM", primed, 1, job_id)
  end
end

if redis.call("HEXISTS", locked, job_id) == 1 then
  if #run > 0 then redis.call("HSET", locked, job_id, run) end
  log("Duplicate")
  drop_queued()
  return job_id
end

if limit <= redis.call("HLEN", locked) then
  -- Wurk's: the lock went to another job after this one's BLMOVE. What that
  -- BLMOVE moved (its own entry, or an unlock's "1") leaves PRIMED with it; the
  -- gem leaves it there for good.
  if redis.call("LREM", primed, 1, job_id) == 0 then
    redis.call("LREM", primed, 1, "1")
  end
  log("Limited")
  return nil
end

if lock_type == "until_expired" and pttl and pttl > 0 then
  redis.call("ZADD", expiring, now + pttl, digest)
else
  local score = lock_score
  if #lock_score == 0 then score = now end
  redis.call("ZADD", digests, score, digest)
end
redis.call("HSET", locked, job_id, #run > 0 and run or now)
drop_queued()

if pttl and pttl > 0 then
  redis.call("PEXPIRE", digest, pttl)
  redis.call("PEXPIRE", locked, pttl)
  redis.call("PEXPIRE", info, pttl)
end

log("Locked")
return job_id
