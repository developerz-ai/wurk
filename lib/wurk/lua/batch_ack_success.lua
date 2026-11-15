-- Every batch script that removes a member from `b-<bid>-jids` or
-- `b-<bid>-pkids` hands back the post-removal state — `pending`, live jids,
-- pending child batches — read inside the same atomic call. That is the
-- batch fire gate: a batch is drained when both sets are empty, and the
-- one script call that empties the second of them is the only one that can
-- observe the drain as a transition. Any other caller that sees both sets
-- empty removed nothing (a reclaimed re-run, a replay after a lost reply),
-- and is exactly the caller that has to re-drive the fire; the callback
-- markers absorb the repeat. A missing `b-<bid>` reports live = -1 so a
-- straggler acking into a deleted or expired batch can never fire it.
--
-- The one caller that observes the drain also records the bid in the fire
-- index (KEYS[5], Batch::FireRecovery's work list) in the same atomic step:
-- the enqueue of the callbacks happens later, on the caller, so an entry
-- that outlives a lost caller is what lets a stranded fire be re-driven
-- cluster-wide. A caller that dies before firing is the reason the index
-- exists; the markers make the eventual re-fire a no-op.
--
-- Pro Batch: ACK a job that completed successfully. SREM from the live
-- jids set and decrement pending iff the jid was a member (idempotent
-- against double-success on a flaky retry). A success also clears any
-- outstanding "currently failing" record for the jid (a retry that finally
-- passed), decrementing `failures` so it converges to the count of jobs
-- *still* failing — Sidekiq Pro semantics, spec §2.5. Also releases the
-- `#jobs` block hold (Batch#jobs), which is a member of the live set too.
-- KEYS = [b-<bid>, b-<bid>-jids, b-<bid>-failed, b-<bid>-pkids, fire index]
-- ARGV = [jid, drain epoch, bid]
-- Returns [removed (1/0), pending, live_jids, pending_kids].
if redis.call("exists", KEYS[1]) == 0 then
  return { redis.call("srem", KEYS[2], ARGV[1]), 0, -1, -1 }
end
if redis.call("srem", KEYS[3], ARGV[1]) == 1 then
  redis.call("hincrby", KEYS[1], "failures", -1)
end
local removed = redis.call("srem", KEYS[2], ARGV[1])
local pending
if removed == 1 then
  pending = redis.call("hincrby", KEYS[1], "pending", -1)
else
  pending = tonumber(redis.call("hget", KEYS[1], "pending")) or 0
end
local live = redis.call("scard", KEYS[2])
local kids = redis.call("scard", KEYS[4])
if removed == 1 and live == 0 and kids == 0 then
  redis.call("zadd", KEYS[5], ARGV[2], ARGV[3])
end
return { removed, pending, live, kids }
