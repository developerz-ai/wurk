# Unreleased

### Fixed

- **sidekiq-unique-jobs, native: a waiting lock's hand-off list always expires.** `<digest>:PRIMED` (and `<digest>:RUN:PRIMED` for a runtime lock) held the entry BLMOVE moved out of `:QUEUED` until the lock script took it out, and had no TTL. Two cases left an entry there for good: a run killed or interrupted between the move and the script, and a script that found the lock taken meanwhile. A production Dragonfly held 130 such lists. The move and a 60-second TTL now go in one pipeline, and the script takes its entry out when the lock is taken. Each reaper run gives the same TTL to every PRIMED list that has none, which cleans up lists already left behind. It never touches `:LOCKED` or the digest ([docs](../unique-jobs.md)).
