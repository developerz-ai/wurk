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
-- ARGV[1] = now, epoch seconds — the flow clock, as `created_at` was written
-- ARGV[2..] = the batch key suffixes (Wurk::Batch::KEY_SUFFIXES), so the one
--             list of what a batch is made of stays in Ruby
-- Returns the number of nodes released, or -1 when the flow was already
-- terminal or was never there, in which case nothing was written.
local flow_key, batches, dead_batches = KEYS[1], KEYS[2], KEYS[3]
local now = ARGV[1]

local state = redis.call('HGET', flow_key, 'state')
if state ~= 'running' and state ~= 'failed' then
  return -1
end

local total = tonumber(redis.call('HGET', flow_key, 'total'))
for i = 0, total - 1 do
  -- '%d' rather than letting Lua render the number: creation spelled these key
  -- names from an integer, and Lua's default float notation does not.
  local node_key = flow_key .. ':' .. string.format('%d', i)
  local bid = redis.call('HGET', node_key, 'bid')
  if bid then
    local base = 'b-' .. bid
    local keys = { base }
    for s = 2, #ARGV do
      keys[#keys + 1] = base .. '-' .. ARGV[s]
    end
    redis.call('UNLINK', unpack(keys))
    redis.call('ZREM', batches, bid)
    redis.call('ZREM', dead_batches, bid)
  end
  redis.call('UNLINK', node_key)
end
redis.call('UNLINK', flow_key .. ':dead')

-- `failed_at` is left alone where there is one: when the flow broke is still
-- true, and still the more useful of the two timestamps to an operator asking
-- why anyone abandoned it.
redis.call('HSET', flow_key, 'state', 'abandoned', 'abandoned_at', now)

return total
