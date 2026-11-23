-- sidekiq-unique-jobs 8.x delete_job_by_digest.lua (on_conflict: :replace): remove
-- the first job carrying the digest from its queue, else the schedule, else the
-- retry set, and return its payload. The gem's copy reads `uniquejobs:digests`
-- without declaring it, which Dragonfly and a strict Redis refuse; here it is KEYS[4].
-- KEYS = [queue:<name>, schedule, retry, uniquejobs:digests]
-- ARGV = [digest]
local digest = ARGV[1]
local per = 50

local total = redis.call("LLEN", KEYS[1])
for index = 0, total, per do
  local items = redis.call("LRANGE", KEYS[1], index, index + per - 1)
  if #items == 0 then break end
  for _, item in ipairs(items) do
    if string.find(item, digest, 1, true) then
      redis.call("LREM", KEYS[1], 1, item)
      return item
    end
  end
end

local score = redis.call("ZSCORE", KEYS[4], digest)
for set = 2, 3 do
  local name = KEYS[set]
  local size = redis.call("ZCARD", name)
  for offset = 0, size, per do
    local items
    if score then
      items = redis.call("ZRANGE", name, score, "+inf", "BYSCORE", "LIMIT", offset, per)
    else
      items = redis.call("ZRANGE", name, offset, offset + per - 1)
    end
    if #items == 0 then break end
    for _, item in ipairs(items) do
      if string.find(item, digest, 1, true) then
        redis.call("ZREM", name, item)
        return item
      end
    end
  end
end
return nil
