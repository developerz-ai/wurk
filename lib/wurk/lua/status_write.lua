-- Job status row write: set the changed fields and re-stamp the TTL in one
-- round trip. A job reporting progress from inside its own loop pays one
-- command per write, not HSET + EXPIRE.
--
-- ARGV[2] is the create gate, and it is the reason this is a script rather
-- than a pipeline. A progress write must never resurrect a row that expired
-- or was deleted mid-run: a bare HSET would recreate `status:<jid>` holding
-- only `progress`/`message` and no `state`, and every reader would then see a
-- job frozen in a state it was never in. Only the lifecycle writes that own a
-- state transition pass "1"; Status::Progress passes "0" and is dropped when
-- the row is gone. EXISTS and HSET have to be atomic for that to hold — the
-- row can expire between two pipelined commands.
--
-- KEYS[1]   = status:<jid>
-- ARGV[1]   = ttl seconds
-- ARGV[2]   = "1" to create the row when absent, "0" to update an existing row only
-- ARGV[3..] = field, value, field, value, ...
-- Returns 1 when the row was written, 0 when the write was dropped.
local key = KEYS[1]
if ARGV[2] ~= '1' and redis.call('EXISTS', key) == 0 then
  return 0
end
local fields = {}
for i = 3, #ARGV do
  fields[i - 2] = ARGV[i]
end
redis.call('HSET', key, unpack(fields))
redis.call('EXPIRE', key, ARGV[1])
return 1
