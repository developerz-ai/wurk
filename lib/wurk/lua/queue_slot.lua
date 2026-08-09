-- Global per-queue concurrency: take one of a capped queue's slots, or report
-- that the cluster is already running as many jobs from it as the cap allows.
--
-- One ZSET per capped queue holding the holders themselves, not a count of
-- them:
--
--   queue_slot:<queue>   ZSET   member = <identity>:<tid>[:<claim>]
--                               score  = the epoch that hold expires unless
--                                        its holder refreshes it
--
-- Storing the holders is what makes the cap crash-safe by construction, and it
-- is the whole reason this is not an INCR/DECR counter:
--
--   * A SIGKILLed holder stops refreshing, so its member ages out of the window
--     on its own and the next acquire reclaims the capacity with no operator
--     action. A counter has nothing equivalent — the DECR that would have freed
--     the slot died with the process, and the queue runs one job short forever.
--   * A member names exactly one holder, so a release that arrives after its
--     own hold already expired and was reclaimed removes nothing, rather than
--     freeing a slot that by then belongs to somebody else. A counter's DECR
--     cannot tell those two apart and hands the same capacity out twice.
--
-- The key needs no TTL of its own: Redis drops a ZSET when its last member
-- goes, so the key's lifetime is already exactly the union of its holders'.
-- Stamping one would be an over-admission trap instead of a safety net — an
-- EXPIRE that fired while long-running jobs still held refreshed slots would
-- delete every live hold at once.
--
-- Capacity is passed in rather than stored, so it is whatever the calling
-- process's own config says. A rolling deploy that changes a cap therefore has
-- both generations asking for their own number, and the larger one is in force
-- for as long as a process running it keeps fetching — bounded by the deploy,
-- and the alternative (a cap stored in Redis by whoever booted last) makes the
-- winner even less predictable.
--
-- KEYS[1] = queue_slot:<queue>
-- ARGV[1] = capacity
-- ARGV[2] = holder token, `<identity>:<tid>` for a release paired on the same
--           thread, `<identity>:<tid>:<claim>` when it is deferred past the
--           next claim (Wurk::QueueSlot.claim_token)
-- ARGV[3] = seconds this hold survives without a refresh
-- Returns 1 when the caller holds a slot, 0 when the queue is at capacity.
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local token = ARGV[2]
local ttl = tonumber(ARGV[3])

-- Redis's clock, never the caller's: the holders sit on different machines, and
-- a skewed one would write expiries the rest of the cluster reads as long
-- elapsed (its slots reclaimed out from under live jobs) or as hours away (its
-- slots stranded after a kill). throttle_slot.lua aligns its slots in here for
-- the same reason.
local t = redis.call('TIME')
local now = tonumber(t[1]) + (tonumber(t[2]) / 1000000)
-- Fixed %.6f rather than tostring: Lua renders a double in 14 significant
-- digits, which for an epoch-with-microseconds silently drops the fraction TIME
-- was called to get.
local now_s = string.format('%.6f', now)
local expires = string.format('%.6f', now + ttl)

-- Reclaim first. A hold is live while its expiry is still ahead of now, so
-- everything at or behind now belonged to a holder that stopped refreshing —
-- killed, hung, or gone in a way that never reached its release.
redis.call('ZREMRANGEBYSCORE', key, '-inf', now_s)

local held = redis.call('ZCARD', key)
if held < capacity then
  redis.call('ZADD', key, expires, token)
  return 1
end

-- At capacity, but the caller may already be one of the holders: an acquire
-- whose reply was lost is retried on the pool's idempotent path, and it has to
-- converge on "you hold it" rather than report a refusal while its member sits
-- in the ZSET — that slot would then be held by a caller that believes it owns
-- nothing, and nothing would release it before the TTL. Read only on the full
-- path; the common one answered above without spending it.
if redis.call('ZSCORE', key, token) then
  redis.call('ZADD', key, expires, token)
  return 1
end

return 0
