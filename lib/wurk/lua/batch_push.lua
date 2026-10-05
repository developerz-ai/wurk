-- Pro Batch: register a job into a batch and push it to its queue
-- atomically. Keeps total/pending in sync with the jids set.
--
-- SADD into the live jids set is the registration guard: total/pending
-- increment only when the jid is genuinely new (SADD == 1). A jid already
-- live is a re-push — a retry or scheduled promotion re-enqueueing a job
-- that never left the batch — so it re-LPUSHes the payload but must NOT
-- recount, or pending inflates past the acks and `:success` never fires
-- (spec §2.3/§2.5: total = distinct jobs added, pending = not-yet-succeeded).
--
-- A jid found in `b-<bid>-died` is a manual retry of a dead job (morgue
-- "retry" / "add to queue") — it rejoins the live set without recounting:
-- total and pending already include it, because a death never decrements
-- pending. When that drains the died set the batch is no longer dead, so
-- the durable `death` success-suppression flag clears and the bid leaves
-- `dead-batches` — a later full drain can then fire `:success` (spec §2.4:
-- success after the dead job is manually retried to success). The
-- `b-<bid>-death` notify dedup key is untouched, so `:death` cannot
-- re-fire.
--
-- The two EXPIRE NX calls are what keep the batch bounded: `b-<bid>-jids` is
-- born here, and only `Batch#ensure_first_flush!` ever stamped a TTL — on the
-- hash alone — so an abandoned or invalidated batch leaked its live-jid set
-- forever. A late re-push (retry, scheduled promotion) can also resurrect an
-- already-expired `b-<bid>` through the HINCRBYs above, again TTL-less. NX
-- stamps only keys that currently have no TTL, so a running batch's clock and
-- the shorter post-success `linger` window (Callbacks#apply_linger) both win.
-- KEYS = [b-<bid>, b-<bid>-jids, queue_list, queues_set, b-<bid>-died, dead-batches]
-- ARGV = [queue_name, jid, job_json, bid, expiry_seconds]
-- Returns 1.
if redis.call("srem", KEYS[5], ARGV[2]) == 1 then
  redis.call("sadd", KEYS[2], ARGV[2])
  if redis.call("scard", KEYS[5]) == 0 then
    redis.call("hdel", KEYS[1], "death")
    redis.call("zrem", KEYS[6], ARGV[4])
  end
else
  if redis.call("sadd", KEYS[2], ARGV[2]) == 1 then
    redis.call("hincrby", KEYS[1], "total", 1)
    redis.call("hincrby", KEYS[1], "pending", 1)
  end
end
redis.call("expire", KEYS[1], ARGV[5], "NX")
redis.call("expire", KEYS[2], ARGV[5], "NX")
redis.call("sadd", KEYS[4], ARGV[1])
redis.call("lpush", KEYS[3], ARGV[3])
return 1
