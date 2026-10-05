-- Reliable fetch across many queues in one round trip: the first non-empty
-- public queue, in the order the caller passed them, has its tail moved onto
-- the head of its own private list.
--
-- Why a script: `Fetcher::Reliable#walk` used to send one LMOVE per queue, so a
-- capsule serving 100 mostly-empty queues paid 100 round trips per fetch before
-- it reached the job on the last one. The walk still leads with a bare LMOVE on
-- the first queue and hands this script the rest only after a miss
-- (Fetcher::ManyQueues has the measurement). The order is decided in Ruby
-- (strict declaration order, or the weighted shuffle, with paused queues
-- already removed), so the script only walks it; it never reorders or filters.
--
-- Every key is passed in KEYS — the private lists are written, the public
-- queues are read and written — so nothing here builds a key name.
--
-- KEYS[2n-1] = queue:<name>                           public queue n
-- KEYS[2n]   = queue:<name>|<host>|<pid>|<nonce>|<i>  its private list
--
-- Returns {n, payload} for the queue the job came from, nil when every queue
-- was empty.
for i = 1, #KEYS, 2 do
  local job = redis.call('LMOVE', KEYS[i], KEYS[i + 1], 'RIGHT', 'LEFT')
  if job then
    return { (i + 1) / 2, job }
  end
end
return nil
