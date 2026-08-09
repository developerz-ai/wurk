-- Advance a flow past one node whose job succeeded: release every dependent
-- this node was the last dependency of, and settle the flow when the last node
-- lands.
--
-- One script because the question a sibling has to answer — "am I the last of
-- my parent's dependencies to finish?" — cannot be read and then decided. Two
-- siblings finishing in the same millisecond both read "one still outstanding",
-- both conclude they are not the last, and the parent never runs; read the
-- other way round they both conclude they are, and it runs twice. Here the
-- decrement *is* the decision, and Redis runs a script to completion with
-- nothing interleaved, so exactly one caller can ever watch a counter reach
-- zero. Nothing counts jobs — the node's batch already did that — so there is
-- no second completion tracker to disagree with the first.
--
-- Every write is claimed, because this arrives as a callback job and callback
-- jobs retry: `Wurk::Batch::Callbacks#fire_complete` enqueues before it marks,
-- deliberately preferring a duplicate `:success` over a lost one. The claim is
-- the node's own `state`, so a replay finds `succeeded` and writes nothing.
--
-- KEYS[1] = flow:<fid>
-- KEYS[2] = queues       the set of known queue names
-- ARGV[1] = the succeeding node's index
-- ARGV[2] = now, epoch seconds — the flow clock, as `created_at` was written
-- ARGV[3] = now, epoch milliseconds — `enqueued_at` for what this releases
-- Returns { pending, class, queue, class, queue, ... }: the flow's remaining
-- node count, then one class/queue pair per released node. { -1 } when the
-- claim was refused, in which case nothing was written.
local flow_key, queues = KEYS[1], KEYS[2]
local index, now, now_ms = ARGV[1], ARGV[2], ARGV[3]

-- Doubles as the flow's existence check, and has to come first: HINCRBY and
-- HSET both create the hash they are given, so a completion arriving after the
-- flow's retention ran out would resurrect its record and its nodes' with no
-- clock on any of them. An expired flow is over, whatever its jobs still think.
local expiry = redis.call('HGET', flow_key, 'expiry')
if not expiry then
  return { -1 }
end

local node_key = flow_key .. ':' .. index
local state = redis.call('HGET', node_key, 'state')
-- `dead` as well as `enqueued`: a job retried out of the morgue to success
-- fires `:success` on a batch whose death mark BATCH_PUSH already cleared, and
-- that is how a failed flow resumes from where it stopped — `failed` is a
-- state, not a tombstone.
if state ~= 'enqueued' and state ~= 'dead' then
  return { -1 }
end
redis.call('HSET', node_key, 'state', 'succeeded')

if state == 'dead' then
  local dead_key = flow_key .. ':dead'
  redis.call('SREM', dead_key, index)
  -- The last death lifted. The flow is running again, and the mark that said
  -- otherwise goes with it rather than being left to contradict the state.
  if redis.call('SCARD', dead_key) == 0 and redis.call('HGET', flow_key, 'state') == 'failed' then
    redis.call('HSET', flow_key, 'state', 'running')
    redis.call('HDEL', flow_key, 'failed_at')
  end
end

local released = {}
local dependents = cjson.decode(redis.call('HGET', node_key, 'dependents'))
for i = 1, #dependents do
  -- Explicit rather than leaning on how Lua renders a number into a key name:
  -- cjson decodes every JSON number to a double, and %.14g only happens to
  -- spell a small integer the way the key that creation wrote is spelled.
  local dep_key = flow_key .. ':' .. string.format('%d', dependents[i])
  if redis.call('HINCRBY', dep_key, 'remaining', -1) == 0 then
    local dep = redis.call('HMGET', dep_key, 'class', 'queue', 'jid', 'bid', 'payload')
    local klass, queue, jid, batch_key = dep[1], dep[2], dep[3], 'b-' .. dep[4]
    redis.call('HSET', dep_key, 'state', 'enqueued')

    -- The registration BATCH_PUSH would have done. This node's batch was born
    -- empty — creation queues the roots and records the rest — so without the
    -- jid joining the live set and the counters moving with it, the batch would
    -- fire `:success` having never held a job.
    redis.call('SADD', batch_key .. '-jids', jid)
    redis.call('EXPIRE', batch_key .. '-jids', expiry, 'NX')
    redis.call('HINCRBY', batch_key, 'total', 1)
    redis.call('HINCRBY', batch_key, 'pending', 1)

    -- `enqueued_at` marks arrival on an immediate queue, which is now and was
    -- not at creation. Spliced into the stored bytes rather than written by a
    -- cjson round trip, which would round a 64-bit argument to a double — the
    -- same surgical patch RELIABLE_SCHEDULE_PROMOTE makes for the same reason.
    -- The local matters: gsub returns a count as well, and passing the call
    -- straight to redis.call would ship it as an extra argument.
    local stamped = string.gsub(dep[5], '^{', '{"enqueued_at":' .. now_ms .. ',', 1)
    redis.call('SADD', queues, queue)
    redis.call('LPUSH', 'queue:' .. queue, stamped)

    released[#released + 1] = klass
    released[#released + 1] = queue
  end
end

local pending = redis.call('HINCRBY', flow_key, 'pending', -1)
if pending == 0 then
  -- Every node succeeded. That holds even if one of them died on the way: a
  -- node that died and was never retried never succeeds, so pending cannot
  -- reach zero while the flow is still carrying a failure.
  redis.call('HSET', flow_key, 'state', 'succeeded', 'finished_at', now)
end

table.insert(released, 1, pending)
return released
