-- Pro Fast API (§11) delete, one window of a queue list at a time.
-- Lua::FastDelete walks the list from the head with a cursor and calls this per
-- window, so Redis is held for one window, never for a copy of the whole queue.
-- KEYS[1] = queue:<name>
-- ARGV[1] = needle: `"jid":"<jid>"` or `"class":"<klass>"`, a plain substring
-- ARGV[2] = cursor: index of the window's first element
-- ARGV[3] = window size
-- ARGV[4] = tombstone, a value no payload can equal
-- Returns {next cursor or -1 when the list is done, removed, first removed
-- payload or false}.
--
-- Every match in the window is LSET to the tombstone at the index LRANGE just
-- read it from, in this same atomic call, then one LREM removes exactly those:
-- only a payload that matched is ever removed, whatever runs between calls.
-- The LREM scans from the end nearer the window.
local key = KEYS[1]
local start = tonumber(ARGV[2])
local window = tonumber(ARGV[3])
local items = redis.call('lrange', key, start, start + window - 1)
local removed, first = 0, false
for i = 1, #items do
  if string.find(items[i], ARGV[1], 1, true) then
    redis.call('lset', key, start + i - 1, ARGV[4])
    removed = removed + 1
    if not first then first = items[i] end
  end
end
if removed > 0 then
  local len = redis.call('llen', key)
  redis.call('lrem', key, (start * 2 > len) and -removed or removed, ARGV[4])
end
if #items < window then return {-1, removed, first} end
return {start + #items - removed, removed, first}
