-- Counts one job into the death counter (Metrics::Deaths). A field already in
-- the hash always counts; a new one counts only while the hash holds fewer than
-- the cap, and into the overflow field past it, so junk payloads cannot grow
-- the hash, or a scrape of it, without bound.
-- KEYS = [deaths hash]
-- ARGV = [field, max fields, overflow field]
-- Returns the field's new count.
local field = ARGV[1]
if redis.call("hexists", KEYS[1], field) == 0 and redis.call("hlen", KEYS[1]) >= tonumber(ARGV[2]) then
  field = ARGV[3]
end
return redis.call("hincrby", KEYS[1], field, 1)
