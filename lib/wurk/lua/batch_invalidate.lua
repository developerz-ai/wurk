-- Pro Batch: invalidate. Only the flag is written — the live jids set is
-- left alone, so jobs still queued, scheduled or retrying keep their
-- membership, short-circuit in the server middleware and ack like a success
-- (spec §12: a job cancelled via `invalidate_all` counts as a success), and
-- the batch drains and fires its callbacks normally. Refuses a missing hash
-- rather than resurrect a bare, TTL-less one.
-- KEYS = [b-<bid>]
-- ARGV = []
-- Returns 1 when flagged, 0 when the batch does not exist.
if redis.call("exists", KEYS[1]) == 0 then
  return 0
end
redis.call("hset", KEYS[1], "invalidated", "1")
return 1
