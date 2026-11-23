-- sidekiq-unique-jobs 8.x delete_by_digest.lua: the queue-time and run-time keys
-- of one digest, and its entry in the index the caller names. Every key is in KEYS.
-- KEYS = [digest, queued, primed, locked, run_digest, run_queued, run_primed, run_locked, index]
local count = redis.call("UNLINK", KEYS[1], KEYS[2], KEYS[3], KEYS[4], KEYS[5], KEYS[6], KEYS[7], KEYS[8])
redis.call("ZREM", KEYS[9], KEYS[1])
return count
