# Unreleased

### Fixed

- With json 3.2.0, whose `script_safe` no longer escapes `/`, a job class or queue holding a `/` was counted in `stat:deaths` under two fields, one written by Ruby and one by the schedule-promote script. Before 3.2.0 the same held for `U+2028` and `U+2029`. Both write the same field again. `/metrics` sums the two spellings already stored.
