-- sidekiq-unique-jobs 8.x delete.lua: drop one digest's queue-time keys and its
-- `uniquejobs:digests` entry. Every key is in KEYS.
-- KEYS = [digest, queued, primed, locked, info, changelog, digests, expiring_digests]
local count = redis.call("ZREM", KEYS[7], KEYS[1])
return count + redis.call("UNLINK", KEYS[1], KEYS[2], KEYS[3], KEYS[4], KEYS[5])
