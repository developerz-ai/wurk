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
-- ARGV[4] = the `status:` key prefix (Wurk::Keys::STATUS_PREFIX)
-- Returns { pending, released, broken }: the flow's remaining node count, then
-- one class/queue pair per node this call put on a queue, then one
-- index/reason pair per node it refused to. { -1, {}, {} } when the claim was
-- refused, in which case nothing was written.
local flow_key, queues = KEYS[1], KEYS[2]
local index, now, now_ms, status_prefix = ARGV[1], ARGV[2], ARGV[3], ARGV[4]

-- Doubles as the flow's existence check, and has to come first: HINCRBY and
-- HSET both create the hash they are given, so a completion arriving after the
-- flow's retention ran out would resurrect its record and its nodes' with no
-- clock on any of them. An expired flow is over, whatever its jobs still think.
local expiry = redis.call('HGET', flow_key, 'expiry')
if not expiry then
  return { -1, {}, {} }
end

local dead_key = flow_key .. ':dead'
local node_key = flow_key .. ':' .. index
local node = redis.call('HMGET', node_key, 'state', 'jid')
local state, node_jid = node[1], node[2]
-- `dead` as well as `enqueued`: a job retried out of the morgue to success
-- fires `:success` on a batch whose death mark BATCH_PUSH already cleared, and
-- that is how a failed flow resumes from where it stopped — `failed` is a
-- state, not a tombstone.
if state ~= 'enqueued' and state ~= 'dead' then
  return { -1, {}, {} }
end
redis.call('HSET', node_key, 'state', 'succeeded')

if state == 'dead' then
  redis.call('SREM', dead_key, index)
  -- The last death lifted. The flow is running again, and the mark that said
  -- otherwise goes with it rather than being left to contradict the state.
  if redis.call('SCARD', dead_key) == 0 and redis.call('HGET', flow_key, 'state') == 'failed' then
    redis.call('HSET', flow_key, 'state', 'running')
    redis.call('HDEL', flow_key, 'failed_at')
  end
end

-- What a chain link is owed, and the three ways it is owed nothing.
--
-- The value comes from this node — the one that just succeeded — because a
-- piped node has exactly one dependency, which Flow::Builder enforces so that
-- "the upstream result" names one value rather than a fan-in's worth of them.
--
-- All three refusals return a reason instead of a value, because the caller
-- asked for the upstream's result and there is no second-best answer. A
-- truncated result in particular is not a lossy display here, it is a wrong
-- argument: the job would run, succeed, and be wrong.
local function upstream()
  local row = redis.call('HMGET', status_prefix .. node_jid,
                         'state', 'result', 'result_truncated', 'result_withheld')
  if row[1] ~= 'complete' then
    return nil, 'piped result is missing: the upstream node left no completed status row'
  elseif row[3] == '1' then
    return nil, 'piped result was truncated at the stored-result cap'
  elseif row[4] == '1' then
    return nil, 'piped result was withheld: the upstream node declares encrypt: true'
  end
  -- A job that returned nil stores no `result` field at all, and nil is a
  -- perfectly good argument — `null` is the JSON for it.
  return row[2] or 'null', nil
end

-- Byte surgery, not a re-encode: cjson maps every JSON number to a double, so
-- decoding the payload to set one argument would round a snowflake id in some
-- other one. Plain find rather than a pattern — the value is the upstream
-- job's own JSON, where `%` is a capture reference to gsub and nothing at all
-- to the caller who returned it.
local function splice(payload, sentinel, value)
  local needle = '"' .. sentinel .. '"'
  local from, to = string.find(payload, needle, 1, true)
  return string.sub(payload, 1, from - 1) .. value .. string.sub(payload, to + 1)
end

-- A node that cannot be built is not enqueued and never will be, so it joins
-- the dead set beside the nodes whose jobs died: same meaning to the flow —
-- this is why it is failed — and the same `SCARD` is what decides recovery.
-- Nothing will ever take a broken node back out, which is correct; there is no
-- job in the morgue to retry.
local function break_node(dep_key, dep_index, reason)
  redis.call('HSET', dep_key, 'state', 'broken', 'error', reason)
  redis.call('SADD', dead_key, dep_index)
  redis.call('EXPIRE', dead_key, expiry, 'NX')
  if redis.call('HGET', flow_key, 'state') == 'running' then
    redis.call('HSET', flow_key, 'state', 'failed', 'failed_at', now)
  end
end

local function release(dep_key, dep, payload)
  local batch_key = 'b-' .. dep[4]
  redis.call('HSET', dep_key, 'state', 'enqueued')

  -- The registration BATCH_PUSH would have done. This node's batch was born
  -- empty — creation queues the roots and records the rest — so without the
  -- jid joining the live set and the counters moving with it, the batch would
  -- fire `:success` having never held a job.
  redis.call('SADD', batch_key .. '-jids', dep[3])
  redis.call('EXPIRE', batch_key .. '-jids', expiry, 'NX')
  redis.call('HINCRBY', batch_key, 'total', 1)
  redis.call('HINCRBY', batch_key, 'pending', 1)

  -- `enqueued_at` marks arrival on an immediate queue, which is now and was
  -- not at creation. Spliced into the stored bytes for the same reason the
  -- piped argument is, and the same surgical patch RELIABLE_SCHEDULE_PROMOTE
  -- makes. The local matters: gsub returns a count as well, and passing the
  -- call straight to redis.call would ship it as an extra argument.
  local stamped = string.gsub(payload, '^{', '{"enqueued_at":' .. now_ms .. ',', 1)
  redis.call('SADD', queues, dep[2])
  redis.call('LPUSH', 'queue:' .. dep[2], stamped)
end

local released, broken = {}, {}
local dependents = cjson.decode(redis.call('HGET', node_key, 'dependents'))
for i = 1, #dependents do
  -- Explicit rather than leaning on how Lua renders a number into a key name:
  -- cjson decodes every JSON number to a double, and %.14g only happens to
  -- spell a small integer the way the key that creation wrote is spelled.
  local dep_index = string.format('%d', dependents[i])
  local dep_key = flow_key .. ':' .. dep_index
  if redis.call('HINCRBY', dep_key, 'remaining', -1) == 0 then
    local dep = redis.call('HMGET', dep_key, 'class', 'queue', 'jid', 'bid', 'payload', 'pipe')
    local payload, refusal = dep[5], nil
    if dep[6] and dep[6] ~= '' then
      local value
      value, refusal = upstream()
      if value then
        payload = splice(payload, dep[6], value)
      end
    end

    if refusal then
      break_node(dep_key, dep_index, refusal)
      broken[#broken + 1] = dep_index
      broken[#broken + 1] = refusal
    else
      release(dep_key, dep, payload)
      released[#released + 1] = dep[1]
      released[#released + 1] = dep[2]
    end
  end
end

local pending = redis.call('HINCRBY', flow_key, 'pending', -1)
if pending == 0 then
  -- Every node succeeded. That holds even if one of them died on the way: a
  -- node that died and was never retried never succeeds, so pending cannot
  -- reach zero while the flow is still carrying a failure.
  redis.call('HSET', flow_key, 'state', 'succeeded', 'finished_at', now)
end

return { pending, released, broken }
