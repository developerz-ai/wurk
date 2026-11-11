-- Pro Fast API (§11) delete, one window of a queue list at a time.
-- Lua::FastDelete walks the list from the head with a cursor and calls this per
-- window, so Redis is held for one window, never for a copy of the whole queue.
-- KEYS[1] = queue:<name>
-- ARGV[1] = needle: `"jid":"<jid>"` or `"class":"<klass>"`, a plain substring
-- ARGV[2] = cursor: index of the window's first element
-- ARGV[3] = window size
-- ARGV[4] = tombstone, a value no payload can equal
-- ARGV[5] = most matches one call rewrites
-- Returns {next cursor or -1 when the list is done, removed, first removed
-- payload or false}.
--
-- Every match in the window is LSET to the tombstone at the index LRANGE just
-- read it from, in this same atomic call, then one LREM removes exactly those:
-- only a payload that matched is ever removed, whatever runs between calls.
-- The LREM scans from the end nearer the window.
--
-- Each LSET walks the list to its index, so a window dense with matches deep
-- in a long list costs one such walk per match. The call therefore stops after
-- ARGV[5] matches and hands the rest of the window to the next call. The LREM
-- still scans to the window (no remove-by-index), which bounds a removing call
-- deep in a long list: measured on a 1M-entry queue, 1,000 matches halfway in
-- held Redis 17ms in one call uncapped, ~10ms per call capped at 100.
local key = KEYS[1]
local start = tonumber(ARGV[2])
local window = tonumber(ARGV[3])
local max_removed = tonumber(ARGV[5])
local items = redis.call('lrange', key, start, start + window - 1)
local removed, first, scanned = 0, false, #items
for i = 1, #items do
  if string.find(items[i], ARGV[1], 1, true) then
    redis.call('lset', key, start + i - 1, ARGV[4])
    removed = removed + 1
    if not first then first = items[i] end
    if removed >= max_removed then
      scanned = i
      break
    end
  end
end
if removed > 0 then
  local len = redis.call('llen', key)
  redis.call('lrem', key, (start * 2 > len) and -removed or removed, ARGV[4])
end
if scanned == #items and #items < window then return {-1, removed, first} end
return {start + scanned - removed, removed, first}
