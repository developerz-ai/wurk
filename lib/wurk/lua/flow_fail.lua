-- Mark one node of a flow dead: its job exhausted its retries, or discarded
-- with `dead: false`.
--
-- Nothing here stops the graph — the batch machinery already did. A node
-- advances its dependents from its batch's `:success`, and a batch holding a
-- dead job fires `:complete` and `:death` but never `:success`, so the
-- dependents of a dead node are not cancelled so much as never released. This
-- write is that fact made visible: without it the flow record would read
-- `running` forever while nothing in it was ever going to move again.
--
-- The node stays addressable and the flow stays recoverable. Retrying the dead
-- job out of the morgue to success takes the node out of the dead set through
-- `flow_advance`, and the flow goes back to `running` — which is why the dead
-- nodes are a set beside the record rather than a flag on it, exactly as
-- `b-<bid>-died` sits beside a batch.
--
-- KEYS[1] = flow:<fid>
-- ARGV[1] = the dying node's index
-- ARGV[2] = now, epoch seconds — the flow clock, as `created_at` was written
-- Returns 1 when this call marked the node dead, 0 when the claim was refused
-- and nothing was written.
local flow_key = KEYS[1]
local index, now = ARGV[1], ARGV[2]

-- Same guard, and the same reason, as flow_advance: every write below creates
-- the key it addresses, so a death arriving after the flow's retention ran out
-- would leave a clockless record of a flow that no longer exists.
local expiry = redis.call('HGET', flow_key, 'expiry')
if not expiry then
  return 0
end

-- The claim. `:death` is enqueued once per batch, but the callback job that
-- carries it retries like any other, and a node already marked must not be
-- re-attributed or re-added to the dead set.
local node_key = flow_key .. ':' .. index
if redis.call('HGET', node_key, 'state') ~= 'enqueued' then
  return 0
end
redis.call('HSET', node_key, 'state', 'dead')

local dead_key = flow_key .. ':dead'
redis.call('SADD', dead_key, index)
redis.call('EXPIRE', dead_key, expiry, 'NX')

-- First death wins the timestamp: a flow that is already failed is failed, and
-- the set records every node that got it there.
if redis.call('HGET', flow_key, 'state') == 'running' then
  redis.call('HSET', flow_key, 'state', 'failed', 'failed_at', now)
end

return 1
