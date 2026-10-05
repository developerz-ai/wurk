-- Pro Batch (§2.4): atomically append one callback triple to the
-- `callbacks` JSON array on the batch hash. Server-side append (vs a
-- Ruby read-modify-write) so two processes registering callbacks on the
-- same reopened batch cannot lose each other's writes. Refuses to write
-- when the batch hash is gone — resurrecting a bare hash would create a
-- batch that can never fire anything.
--
-- The stored text is spliced, never decoded and re-encoded: cjson maps
-- every number to a double and has no empty-array type, so a round trip
-- rewrote 17-digit integers in *every* entry as `1.2345678901234568e+16`,
-- turned `[]` into `{}` and escaped `/` — corrupting callbacks registered
-- long before. Instead a byte scanner walks the array's top-level entries
-- (string- and escape-aware) to count them and compare each, byte for
-- byte, with the new entry, and the new entry's own JSON text is appended
-- before the closing bracket. Both sides of the comparison are Ruby's
-- `to_json` output — the first flush writes the array with the same
-- generator — so an identical triple is a no-op and past the cap the
-- append is refused.
-- KEYS = [b-<bid>]
-- ARGV = [callback triple JSON, event name, max callbacks]
-- Returns -1 when the batch hash does not exist and -2 when the cap
-- refused the append; otherwise the event's fired flag ("1", or nil when
-- it has not fired yet).
if redis.call("exists", KEYS[1]) == 0 then
  return -1
end
local raw = redis.call("hget", KEYS[1], "callbacks") or ""
local entry = ARGV[1]
local count, depth, start, in_str, esc = 0, 0, 0, false, false
for i = 1, #raw do
  local c = string.byte(raw, i)
  if in_str then
    if esc then
      esc = false
    elseif c == 92 then
      esc = true
    elseif c == 34 then
      in_str = false
    end
  elseif c == 34 then
    in_str = true
  elseif c == 91 or c == 123 then
    depth = depth + 1
    if depth == 2 then start = i end
  elseif c == 93 or c == 125 then
    if depth == 2 then
      count = count + 1
      if string.sub(raw, start, i) == entry then
        return redis.call("hget", KEYS[1], ARGV[2])
      end
    end
    depth = depth - 1
  end
end
if count >= tonumber(ARGV[3]) then
  return -2
end
local updated
local close = string.find(raw, "%]%s*$")
if count == 0 or not close then
  updated = "[" .. entry .. "]"
else
  updated = string.sub(raw, 1, close - 1) .. "," .. entry .. "]"
end
redis.call("hset", KEYS[1], "callbacks", updated)
return redis.call("hget", KEYS[1], ARGV[2])
