-- Limiter registration: metadata HASH + `lmtr-list` membership, atomically.
-- KEYS[1] = lmtr:<name>   metadata HASH (type / options / fingerprint)
-- KEYS[2] = lmtr-list     SET of every registered limiter name
-- ARGV[1] = name
-- ARGV[2] = type
-- ARGV[3] = options JSON
-- ARGV[4] = fingerprint
-- ARGV[5] = ttl seconds
-- Returns 1 when the name was added to `lmtr-list`, 0 when it was already one.
--
-- Three round trips collapsed into one: the spec blesses interpolated names
-- (`stripe-<user_id>`), so a limiter is constructed per job and registration
-- sits on the enqueue path rather than on boot.
--
-- The SADD only fires when this HSET created the metadata (the limiter is new,
-- or its ttl had lapsed), so a set that can hold millions of members is not
-- rewritten by every construction. The gate is safe only because it is atomic
-- with the HSET: limiter_list_sweep.lua re-reads the same HASH inside its own
-- atomic step, so the pair can never interleave into "metadata written,
-- membership swept", which with the gate would hide a live limiter from the
-- dashboard until its ttl ran out.
local created = redis.call('HSET', KEYS[1], 'type', ARGV[2], 'options', ARGV[3], 'fingerprint', ARGV[4])
redis.call('EXPIRE', KEYS[1], ARGV[5])
if created > 0 then
  return redis.call('SADD', KEYS[2], ARGV[1])
end
return 0
