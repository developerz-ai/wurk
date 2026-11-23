-- sidekiq-unique-jobs 8.x queue.lua: claim the digest and queue this jid for the
-- blocking path (Locksmith#lock with a wait, #execute). Every key is in KEYS.
-- KEYS = [digest, queued, primed, locked, info, changelog, digests, expiring_digests]
-- ARGV = [jid, pttl, lock_type, limit, lock_score, now, max_history, script_name]
local digest, queued, locked, changelog = KEYS[1], KEYS[2], KEYS[4], KEYS[6]
local job_id, pttl, limit = ARGV[1], tonumber(ARGV[2]), tonumber(ARGV[4])
local now, max_history, script_name = tonumber(ARGV[6]), tonumber(ARGV[7]), ARGV[8]

local function log(message, prev_jid)
  if not max_history or max_history == 0 then return end
  local entry = cjson.encode({digest = digest, job_id = job_id, script = script_name, message = message, time = now, prev_jid = prev_jid})
  redis.call("ZADD", changelog, now, entry)
  redis.call("ZREMRANGEBYRANK", changelog, 0, -1 * max_history)
  redis.call("PUBLISH", changelog, entry)
end

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
    return prev_jid
  end
end

redis.call("LPUSH", queued, job_id)
if pttl and pttl > 0 then
  redis.call("PEXPIRE", digest, pttl)
  redis.call("PEXPIRE", queued, pttl)
end

log("Queued")
return job_id
