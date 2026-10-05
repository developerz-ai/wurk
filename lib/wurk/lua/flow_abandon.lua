-- The kill switch: give up on a flow and release what it is holding.
--
-- A flow that is stuck is stuck for a reason nothing in Wurk can see — a queue
-- flushed under it, a node's job deleted by hand, a graph waiting on work that
-- is never coming back. There is no reaper for that (a second source of truth
-- about whether a flow is alive, needing a leader to run in exactly one
-- process); there is retention, and there is this, an operator saying so.
--
-- What goes: every node record, every node batch and its subkeys, the dead-node
-- set, and the nodes' entries in both batch indexes. That is the weight — a
-- batch is ~9 keys and there is one per node.
--
-- What stays: the flow's own record, marked `abandoned`, on the clock it was
-- created with. A flow that vanishes is indistinguishable from one that was
-- never created, and the record is also what keeps the release safe: every
-- write in flow_advance/flow_fail claims on a node record this script deleted,
-- so the jobs still queued against this flow ack into nothing rather than
-- rebuilding it. Deleting the record would remove that guard, not add to it.
--
-- The claim is the flow's state. Only a live flow can be abandoned: a
-- succeeded one is not stuck, and re-abandoning an abandoned one would move
-- the timestamp of a decision that was already made.
--
-- KEYS[1] = flow:<fid>
-- KEYS[2] = batches       index of every batch
-- KEYS[3] = dead-batches  index of every batch holding a dead job
-- KEYS[4..] = everything released: each node record, each node batch and its
--             subkeys, the dead-node set. Resolved by the caller from the
--             graph (node bids never change once created) so the script only
--             touches declared keys — Redis Cluster and Dragonfly both refuse a
--             key built inside Lua.
-- ARGV[1] = now, epoch seconds — the flow clock, as `created_at` was written
-- ARGV[2..] = the node bids, for the two batch indexes
-- Returns the number of nodes released, or -1 when the flow was already
-- terminal or was never there, in which case nothing was written.
local flow_key, batches, dead_batches = KEYS[1], KEYS[2], KEYS[3]
local now = ARGV[1]

local state = redis.call('HGET', flow_key, 'state')
if state ~= 'running' and state ~= 'failed' then
  return -1
end

-- Sliced so a 1,000-node graph (~10 keys a node) never asks unpack for more
-- values than the Lua stack holds.
local SLICE = 500
for from = 4, #KEYS, SLICE do
  redis.call('UNLINK', unpack(KEYS, from, math.min(from + SLICE - 1, #KEYS)))
end
for i = 2, #ARGV do
  redis.call('ZREM', batches, ARGV[i])
  redis.call('ZREM', dead_batches, ARGV[i])
end

-- `failed_at` is left alone where there is one: when the flow broke is still
-- true, and still the more useful of the two timestamps to an operator asking
-- why anyone abandoned it.
redis.call('HSET', flow_key, 'state', 'abandoned', 'abandoned_at', now)

return tonumber(redis.call('HGET', flow_key, 'total'))
