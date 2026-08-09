-- Debounce: collapse a burst of enqueues of the same key down to one
-- scheduled job carrying the LAST payload, fired after `wait` seconds of
-- quiet.
--
-- One script, not read-then-write. Reading the pending member, pulling it back
-- out of `schedule`, writing the replacement and restamping the burst all have
-- to land without another producer interleaving: two processes debouncing the
-- same key at the same instant would otherwise each see "nothing pending" and
-- each ZADD, which is exactly the one thing a collapse policy must not do.
--
-- ARGV[2] is the starvation guard, and it is why `first` is stored at all. A
-- key re-enqueued faster than `wait` pushes its own fire time forward on every
-- push and never runs — the classic debounce bug. `first` pins when the burst
-- opened, and the fire time is capped at first + max_wait, so a permanently
-- busy key still fires on a fixed cadence instead of never.
--
-- What lands in `schedule` is an ordinary scheduled job: score = epoch
-- seconds, member = the caller's job JSON, no side structures. Wurk's
-- ScheduledSet, the dashboard and a stock Sidekiq poller all read it as any
-- other `perform_in` — a debounced job is not a distinguishable kind of job.
--
-- The clock is Redis's, not the caller's. Producers spread across machines
-- with skewed clocks then debounce against one window, and a host whose clock
-- runs fast cannot drag the max_wait cap forward for everyone else.
--
-- KEYS[1] = debounce:<digest>
-- KEYS[2] = schedule
-- ARGV[1] = wait seconds (float ok)
-- ARGV[2] = max_wait seconds measured from the first enqueue; 0 = uncapped
-- ARGV[3] = job JSON, already stripped of `at`/`enqueued_at` (the ZSET member)
-- ARGV[4] = grace seconds the key outlives its own entry by
-- Returns {replaced, fire_at, burst_started_at}; `replaced` is 1 when this
-- call displaced a still-pending sibling, 0 when it opened a new burst.
local dkey, zkey = KEYS[1], KEYS[2]
local wait = tonumber(ARGV[1])
local max_wait = tonumber(ARGV[2])
local member = ARGV[3]
local grace = tonumber(ARGV[4])

local t = redis.call('TIME')
local now = tonumber(t[1]) + (tonumber(t[2]) / 1000000)

local replaced = 0
local first = now
local prev = redis.call('HMGET', dkey, 'member', 'first')
-- The ZREM doubles as the liveness test. A recorded member that is no longer
-- in `schedule` has already been promoted by the poller (or deleted from the
-- dashboard): its burst is over, so this enqueue opens a new one. Carrying the
-- old `first` forward instead would cap a fresh burst against a deadline that
-- has already passed and fire it immediately, forever.
if prev[1] and redis.call('ZREM', zkey, prev[1]) == 1 then
  replaced = 1
  first = tonumber(prev[2]) or now
end

local at = now + wait
if max_wait > 0 then
  local cap = first + max_wait
  if at > cap then at = cap end
end

-- Fixed %.6f rather than letting Redis format the double: TIME is
-- microsecond-resolution, so six decimals is lossless here, and the caller
-- gets back a score it can compare byte-for-byte with what is in the ZSET.
local score = string.format('%.6f', at)
local started = string.format('%.6f', first)
redis.call('ZADD', zkey, score, member)
redis.call('HSET', dkey, 'member', member, 'first', started)
-- Whole seconds, rounded up, floored at 1: the key must outlive the entry it
-- guards. If it expires first, the next enqueue sees no pending member and
-- ZADDs a second entry alongside the one still sitting in `schedule` — the
-- grace covers however long the poller takes to promote a due job.
redis.call('EXPIRE', dkey, math.max(1, math.ceil((at - now) + grace)))

return { replaced, score, started }
