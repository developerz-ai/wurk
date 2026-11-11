-- Takes one orphaned payload off a private list and decides, before anyone can
-- see it, where it goes: back onto its public queue's fetch end, or into the
-- dead set once the poison-pill counter passes the threshold. Pushing first and
-- counting after handed a poison job to a worker parked in BLMOVE, then killed
-- it into the dead set while it ran (Fetcher::OrphanReclaim).
--
-- The payload is located from the tail, where the reaper peeked it. Gone means
-- someone else moved it, and nothing is touched. Push before remove, as in the
-- requeue scripts, and the counter last: a write refused part way through must
-- leave the job where it was, and a refused counter only leaves it short.
-- SET EX is INCR + EXPIRE in one write, so the counter never lacks its TTL.
-- KEYS = [private_list, public_queue, dead, counter (only for a payload with a jid)]
-- ARGV = [payload, threshold, ttl_seconds, now]
-- Returns the recovery count (0 without a counter), nil when the payload is gone.
if not redis.call("lpos", KEYS[1], ARGV[1], "RANK", -1) then
  return nil
end
local count = 0
if KEYS[4] then
  count = (tonumber(redis.call("get", KEYS[4])) or 0) + 1
end
if count > tonumber(ARGV[2]) then
  redis.call("zadd", KEYS[3], ARGV[4], ARGV[1])
else
  redis.call("rpush", KEYS[2], ARGV[1])
end
redis.call("lrem", KEYS[1], -1, ARGV[1])
if KEYS[4] then
  redis.call("set", KEYS[4], count, "EX", ARGV[3])
end
return count
