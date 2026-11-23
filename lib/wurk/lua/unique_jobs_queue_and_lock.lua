-- sidekiq-unique-jobs 8.x queue_and_lock.lua, the same writes to the same keys.
-- Wurk::UniqueJobs::Locksmith#lock without a wait. Every key it touches is in KEYS.
-- KEYS = [digest, queued, primed, locked, info, changelog, digests, expiring_digests]
-- ARGV = [jid, pttl, lock_type, limit, lock_score, now, max_history, script_name]
local digest, queued, locked, info, changelog, digests, expiring = KEYS[1], KEYS[2], KEYS[4], KEYS[5], KEYS[6], KEYS[7], KEYS[8]
local job_id, pttl, lock_type, limit, lock_score = ARGV[1], tonumber(ARGV[2]), ARGV[3], tonumber(ARGV[4]), ARGV[5]
local now, max_history, script_name = tonumber(ARGV[6]), tonumber(ARGV[7]), ARGV[8]

local function log(message, prev_jid)
  if not max_history or max_history == 0 then return end
  local entry = cjson.encode({digest = digest, job_id = job_id, script = script_name, message = message, time = now, prev_jid = prev_jid})
  redis.call("ZADD", changelog, now, entry)
  redis.call("ZREMRANGEBYRANK", changelog, 0, -1 * max_history)
  redis.call("PUBLISH", changelog, entry)
end

if limit <= 1 then
  if redis.call("HLEN", locked) > 0 then
    if redis.call("HEXISTS", locked, job_id) == 1 then
      log("Duplicate")
      return job_id
    end
    log("Limited")
    return nil
  end
  redis.call("SET", digest, job_id)
else
  if redis.call("HEXISTS", locked, job_id) == 1 then
    log("Duplicate")
    return job_id
  end
  if not redis.call("SET", digest, job_id, "NX") then
    local prev_jid = redis.call("GET", digest)
    if prev_jid == job_id then
      log("Duplicate")
      return job_id
    end
    if limit > redis.call("HLEN", locked) and redis.call("LLEN", queued) < limit then
      redis.call("SET", digest, job_id)
    else
      log("Limit exceeded", prev_jid)
      return nil
    end
  end
  if limit <= redis.call("HLEN", locked) then
    log("Limited")
    return nil
  end
end

if lock_type == "until_expired" and pttl and pttl > 0 then
  redis.call("ZADD", expiring, now + pttl, digest)
else
  local score = lock_score
  if #lock_score == 0 then score = now end
  redis.call("ZADD", digests, score, digest)
end
redis.call("HSET", locked, job_id, now)

if pttl and pttl > 0 then
  redis.call("PEXPIRE", digest, pttl)
  redis.call("PEXPIRE", locked, pttl)
  redis.call("PEXPIRE", info, pttl)
end

log("Locked")
return job_id
