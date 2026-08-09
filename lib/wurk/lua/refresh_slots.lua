-- Global per-queue concurrency: extend every slot this process is still using,
-- as one call riding the heartbeat's own pipeline.
--
-- A hold expires on its own so that a SIGKILLed holder's capacity comes back
-- without operator action (see queue_slot.lua). That only works if a *live*
-- holder keeps saying so, and the beat is the statement this process already
-- makes every 10s — so the refresh joins it rather than adding traffic of its
-- own. A job that outlives QueueSlot::TTL_SECONDS therefore keeps its slot for
-- as long as its process keeps beating, and loses it in the same breath the
-- process disappears from the `processes` set.
--
-- ZADD XX, never a plain ZADD: a refresh may only ever extend a hold this
-- process still has. If a hold already expired — this process was partitioned
-- for longer than the TTL — the capacity has by now been handed to somebody
-- else, and re-adding the member would put the queue over its cap with two
-- holders that each believe the slot is theirs. Losing the hold instead leaves
-- the job running off the books, which under-counts for the rest of that job
-- and then converges: its release names a member that is already gone and
-- frees nothing.
--
-- KEYS[i]     = queue_slot:<queue>, one per hold
-- ARGV[1]     = seconds a refreshed hold survives
-- ARGV[i + 1] = the holder token to refresh in KEYS[i]
-- Returns the number of holds that were still live and got extended.
local ttl = tonumber(ARGV[1])

-- Redis's clock, for the reason queue_slot.lua spells out: the holders sit on
-- different machines and a skewed one writes expiries the rest of the cluster
-- misreads. %.6f because Lua renders a double in 14 significant digits, which
-- drops an epoch's microseconds.
local t = redis.call('TIME')
local expires = string.format('%.6f', tonumber(t[1]) + (tonumber(t[2]) / 1000000) + ttl)

local refreshed = 0
for i = 1, #KEYS do
  refreshed = refreshed + redis.call('ZADD', KEYS[i], 'XX', 'CH', expires, ARGV[i + 1])
end
return refreshed
