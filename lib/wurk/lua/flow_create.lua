-- Create a whole flow: the flow record, one record and one batch per node,
-- and the queue entries for the nodes that have nothing to wait for.
--
-- One script because creation is the one step of a flow that cannot be
-- partially applied. A flow whose node records landed but whose roots did not
-- reach a queue is a graph nothing will ever advance; roots without records is
-- work running against a flow that does not exist. Neither raises, neither is
-- visible, and both are worse than a flow that was refused outright — so the
-- graph arrives as one write or not at all.
--
-- The size of that write is what Flow::MAX_NODES bounds. Redis runs a script
-- to completion with nothing else interleaved, so the whole graph is one
-- uninterrupted sweep: at the cap it is ~7k commands, a few milliseconds, and
-- the reason the cap is 1,000 rather than a configurable number.
--
-- Field names live here rather than travelling in the envelope because the
-- batch hash's names already do — BATCH_PUSH increments "total" and "pending"
-- by name, the acks read "failures" — so this is the same layout spelled the
-- same way, and `Flow::Creation#batch_fields` is its counterpart in Ruby.
--
-- KEYS[1] = flow:<fid>
-- KEYS[2] = flows          index of every flow
-- KEYS[3] = batches        index of every batch; a node's batch is a batch
-- KEYS[4] = queues         the set of known queue names
-- ARGV[1] = fid
-- ARGV[2] = created_at, epoch seconds — the batch clock (Batch#first_flush_hash)
-- ARGV[3] = seconds every key this script creates expires in
-- ARGV[4] = depth, longest dependency path
-- ARGV[5] = width, the most edges on either side of any one node
-- ARGV[6] = callback queue for every node batch's callbacks
-- ARGV[7] = index trim cutoff score, exclusive  (Batch.trim_bounds)
-- ARGV[8] = index trim rank bound, negative     (Batch.trim_bounds)
-- ARGV[9..] = one JSON envelope per node, in topological order. Every value in
--             it is a string, so nothing here has to format a number and the
--             job payload it carries is copied through verbatim rather than
--             decoded — cjson maps JSON numbers to doubles, and a round trip
--             would corrupt an integer argument past 2^53.
-- Returns the number of node jobs enqueued, or -1 when a flow already exists
-- under this fid and nothing was written.
local flow_key, flows, batches, queues = KEYS[1], KEYS[2], KEYS[3], KEYS[4]
local fid = ARGV[1]
local now = ARGV[2]
local expiry = ARGV[3]
local callback_queue = ARGV[6]
local FIRST_NODE = 9

-- The claim. A creation whose reply was lost is retried on the pool's
-- idempotent path, and the retry must not enqueue the roots a second time —
-- so an existing flow key means this write already applied, and the replay
-- reports that instead of doubling it. Wurk::Flow refuses a second #run from
-- the same object, so nothing else can reach this branch.
if redis.call('EXISTS', flow_key) == 1 then
  return -1
end

-- '%d' rather than letting Lua render the number: everything this script
-- writes is a string the caller compares byte for byte, and a count has no
-- business reaching Redis in Lua's default float notation.
local total = string.format('%d', #ARGV - FIRST_NODE + 1)
redis.call('HSET', flow_key,
  'created_at', now,
  'state', 'running',
  'total', total,
  -- Nodes that have not succeeded yet. All of them, until a node does.
  'pending', total,
  'depth', ARGV[4],
  'width', ARGV[5])
redis.call('EXPIRE', flow_key, expiry, 'NX')

local enqueued = 0
for i = FIRST_NODE, #ARGV do
  local node = cjson.decode(ARGV[i])
  local node_key = flow_key .. ':' .. node.i
  local batch_key = 'b-' .. node.bid
  -- A node with nothing to wait for is queued now; the rest are queued by the
  -- callback that observes their last dependency succeed. `state` is the whole
  -- difference, so the two paths cannot disagree about which nodes went out.
  local queued = node.state == 'enqueued'
  local live = queued and '1' or '0'

  redis.call('HSET', node_key,
    'index', node.i,
    'name', node.name,
    'class', node.class,
    'queue', node.queue,
    'jid', node.jid,
    'bid', node.bid,
    'state', node.state,
    'deps', node.deps,
    'dependents', node.dependents,
    -- Dependencies still to succeed. The completion step decrements this; at
    -- zero the node's payload below is what gets pushed.
    'remaining', node.remaining,
    'payload', node.payload)
  redis.call('EXPIRE', node_key, expiry, 'NX')

  -- The node's batch, written here rather than left to BATCH_PUSH: that script
  -- only moves counters, so a batch born there would carry no `callbacks` field
  -- and the node's success would advance nothing. The callback has to exist
  -- before the job can run, which is to say it has to be part of this write.
  redis.call('HSET', batch_key,
    'created_at', now,
    'description', node.desc,
    'callback_queue', callback_queue,
    'callback_class', '',
    'parent_bid', '',
    'tags', '[]',
    'linger', '',
    'callbacks', node.cb,
    'total', live,
    'pending', live,
    'failures', '0')
  redis.call('EXPIRE', batch_key, expiry, 'NX')
  redis.call('ZADD', batches, now, node.bid)

  if queued then
    redis.call('SADD', batch_key .. '-jids', node.jid)
    redis.call('EXPIRE', batch_key .. '-jids', expiry, 'NX')
    redis.call('SADD', queues, node.queue)
    redis.call('LPUSH', 'queue:' .. node.queue, node.payload)
    enqueued = enqueued + 1
  end
end

redis.call('ZADD', flows, now, fid)
-- Both indexes, both bounds, once for the whole graph rather than once per
-- node: nothing else ever shrinks either set, and the per-node cost of a trim
-- that removes the same members every time is pure waste.
redis.call('ZREMRANGEBYSCORE', flows, '-inf', ARGV[7])
redis.call('ZREMRANGEBYRANK', flows, 0, ARGV[8])
redis.call('ZREMRANGEBYSCORE', batches, '-inf', ARGV[7])
redis.call('ZREMRANGEBYRANK', batches, 0, ARGV[8])

return enqueued
