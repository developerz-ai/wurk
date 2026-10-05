-- Throttle-to-slot: admit at most one job per identity per fixed slot of
-- wall-clock time and drop everything else that arrives inside it.
--
-- Slots are floor-aligned against the Unix epoch — the index is
-- floor(now / slot) — so `slot = 60` means the calendar minute and every
-- producer means the same minute by it. pg-boss derives `singleton_on` the
-- same way (floor(extract(epoch from now()) / singletonSeconds)).
--
-- Aligning is what makes the KEY, not the TTL, carry the throttle: slot k and
-- slot k+1 are different key names, so an expire that fires late — or the
-- one-second floor on EX granularity near a boundary — can neither hand out a
-- second admission inside one slot nor refuse the first of the next. The TTL
-- is left with nothing to do but reclaim the key.
--
-- The caller aligns against Redis's TIME, read on the same connection just
-- before this script, never its own clock: producers sit on machines with
-- their own clocks, and two of them a second apart either side of a boundary
-- would compute different indices and both be admitted. The resolved key is
-- passed in KEYS[1] so the script touches only a declared key — Redis Cluster
-- and Dragonfly both refuse a key built inside Lua (#91, the bucket limiter's
-- precedent).
--
-- Losing SET NX and then reading the winner is atomic here, so the gap
-- Wurk::Unique's two-command Ruby version has to defend against — the key
-- expiring between the failed SET and the GET — does not exist: nothing
-- interleaves, and Redis does not expire keys mid-script.
--
-- KEYS[1] = throttle:<digest>:<slot index>
-- ARGV[1] = whole seconds to the slot boundary, rounded up (the key's EX)
-- ARGV[2] = the calling job's jid
-- ARGV[3] = slot_ends_at, a fixed %.6f epoch, returned verbatim
-- Returns {admitted, jid, slot_ends_at}. `jid` is whoever owns the slot: the
-- caller when admitted, the incumbent when dropped.
local key = KEYS[1]
local ttl = ARGV[1]
local jid = ARGV[2]
local ends = ARGV[3]

if redis.call('SET', key, jid, 'NX', 'EX', ttl) then
  return { 1, jid, ends }
end

-- Unconditionally a string: SET NX only just failed, which means the key was
-- there, and Redis does not expire keys part-way through a script. So there is
-- no missing-holder case to encode — which matters, because a nil inside a
-- reply table truncates it at that element rather than arriving as a null.
local holder = redis.call('GET', key)
-- Our own jid already holding the slot is a re-push, not a duplicate: a retry
-- or a scheduled promotion runs the client chain again carrying the same jid,
-- the same case Wurk::Unique's client middleware re-admits. Dropping it would
-- lose the job outright, and a genuine duplicate can never arrive with this
-- jid. It also makes a replayed call converge on "won" rather than reporting a
-- drop that never happened.
if holder == jid then
  return { 1, jid, ends }
end

return { 0, holder, ends }
