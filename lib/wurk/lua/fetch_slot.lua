-- Reliable fetch under a global per-queue concurrency cap: the admission
-- decision and the LMOVE that claims the job, in one script.
--
-- Why one script and not two calls: `Fetcher::Reliable#lmove` already spends
-- exactly one pipelined round trip per job (the held ACK's LREM rides in front
-- of the LMOVE), and a cap bolted on as "acquire, fetch, release" measured
-- 2.2x-2.6x the uncapped cost — roughly 450-550 us per fetch+execute — in
-- docs/plans/2026/08/07/101-beyond-sidekiq/10-global-concurrency-measurement.md.
-- A capped queue has to cost the same one round trip an uncapped one does, so
-- the gate joins the fetch instead of bracketing it.
--
-- It also has to be one script for correctness, not only for cost: a pipeline
-- cannot branch, so an acquire pipelined in front of an LMOVE would move a job
-- into this process's private list whether or not the acquire succeeded, and
-- the loser would then have to push it back.
--
-- The slot ledger is Wurk::QueueSlot's, unchanged — one ZSET per capped queue
-- holding TTL'd holders rather than a count, so a SIGKILLed holder's capacity
-- returns on its own. See lib/wurk/lua/queue_slot.lua for why it is not a
-- counter.
--
-- KEYS[1] = queue_slot:<queue>                     the cap's ledger
-- KEYS[2] = queue:<name>                           public queue
-- KEYS[3] = queue:<name>|<host>|<pid>|<nonce>|<i>  this process's private list
-- ARGV[1] = capacity, the cluster-wide ceiling for this queue
-- ARGV[2] = holder token for this claim, `<identity>:<tid>:<n>`
-- ARGV[3] = seconds this hold survives without a refresh
--
-- Returns {0}          the cluster is at capacity; nothing was moved
--         {1}          capacity was free but the queue was empty; no slot taken
--         {2, payload} the job is in the private list and the slot is held
local slots = KEYS[1]
local public_queue = KEYS[2]
local private_queue = KEYS[3]
local capacity = tonumber(ARGV[1])
local token = ARGV[2]
local ttl = tonumber(ARGV[3])

-- Redis's clock, never the caller's: holders sit on different machines, and a
-- skewed one writes expiries the rest of the cluster reads as long elapsed (its
-- slots reclaimed out from under live jobs) or as hours away (its slots
-- stranded after a kill). queue_slot.lua takes the same care, for the same
-- reason; %.6f rather than tostring because Lua renders a double in 14
-- significant digits, which silently drops an epoch's microseconds.
local t = redis.call('TIME')
local now = tonumber(t[1]) + (tonumber(t[2]) / 1000000)
local now_s = string.format('%.6f', now)
local expires = string.format('%.6f', now + ttl)

-- Reclaim first: everything at or behind now belonged to a holder that stopped
-- refreshing — killed, hung, or gone in a way that never reached its release.
redis.call('ZREMRANGEBYSCORE', slots, '-inf', now_s)

-- Refuse before touching either list, so a queue at capacity costs one round
-- trip and moves nothing. ZSCORE is only spent on the full path: the caller may
-- already be this member — a claim whose reply was lost is retried on the pool's
-- idempotent path with the same token, and has to converge on "you hold it"
-- rather than be refused against its own member, which would leave a slot held
-- by a caller that believes it owns nothing until the TTL took it.
--
-- Only that. A token names one claim, not one thread (QueueSlot.claim_token), so
-- a thread whose previous job's release has not landed yet is a different member
-- here and is refused like anybody else while the queue is full. That is the
-- cap doing its job: the ledger says N jobs' worth of capacity is spoken for,
-- and it is right until the release lands.
if redis.call('ZCARD', slots) >= capacity and not redis.call('ZSCORE', slots, token) then
  return { 0 }
end

local job = redis.call('LMOVE', public_queue, private_queue, 'RIGHT', 'LEFT')
if not job then
  -- Nothing to run, so nothing to hold: an empty queue must not spend capacity
  -- the rest of the cluster could be using. Deliberately does not release an
  -- existing hold either — the holder may be this thread's still-unfinished
  -- job, and releasing is the caller's business, never the fetch's.
  return { 1 }
end

-- Last, and only now that the job is ours: the ZADD both takes a free slot and
-- refreshes one this token already held, so a replayed claim can never count
-- itself twice.
redis.call('ZADD', slots, expires, token)
return { 2, job }
