# frozen_string_literal: true

require "wurk"

# End-to-end: enqueue, BLMOVE to private list, pop, run middleware chain,
# invoke perform, ACK. Single child, single thread, no real work in perform.
#
# STUB — tracked in #259. fetch+execute is one of the four "Faster" pillar
# critical paths (CLAUDE.md), so this gap is flagged loudly: while the stub
# stands the bench gate cannot verify perf claims on the end-to-end path.
# Emitting a benchmark/ips line for `1 + 1` false-positived the noise-aware
# gate (~14% cross-run jitter on a ~50M i/s baseline > ±5.7% band), so the
# stub is a no-op + STDERR warning instead.

warn "[wurk bench] MISSING: fetch+execute driver (TODO, tracked in #259) — " \
     "critical-path gate cannot verify regressions until this lands"
puts "fetch_execute bench: TODO (see #259)"
