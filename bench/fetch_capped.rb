# frozen_string_literal: true

require "benchmark/ips"
require "logger"
require "wurk"
require_relative "support"

# Step 1 of docs/plans/2026/08/07/101-beyond-sidekiq/10-global-concurrency.md:
# "Measure first... so the cost is known, not argued." Slice 10 has not landed
# — there is no `lib/wurk/fetcher/reliable.rb` gate, no config option, no
# `lib/wurk/lua/queue_slot.lua` — so this is NOT a preview of the real
# integration. It is a standalone probe: the REAL fetch+execute path
# (identical to bench/fetch_execute.rb) reported once uncapped and once
# wrapped in a throwaway acquire/release Lua pair, EVAL'd directly rather than
# registered in lib/wurk/lua.rb, to put a number on "one extra atomic Redis
# round-trip either side of a fetch" before slice 10 argues about it in
# review.
#
# The slot script below is the cheapest correct-ish shape a cap COULD take — a
# bare counter with a TTL safety net — not a claim about what slice 10 ships.
# The plan's own constraint #3 (crash safety) wants a TTL'd holder key PER
# SLOT, refreshed by the heartbeat, which is a different (likely pricier)
# shape. Re-run this against that shape once it exists; don't trust this
# number past "roughly what a single extra round trip costs here".
#
# Excluded from `rake bench` (Rakefile UNGATED_SCRIPTS) until slice 10 lands a
# real gate and decides ship-vs-defer on real numbers — run explicitly via
# `rake bench:fetch_capped`.
#
# Runs on a dedicated Redis logical DB (default 8, unused by every other
# bench/*.rb) so a stray dev/CI Redis with real data is never drained or
# flushed, and so this can run alongside fetch_execute.rb without contending
# for the same queue. DB 0 is never touched.
#
# Same anti-drain discipline as fetch_execute.rb: a queue that runs dry mid-
# batch turns a several-second run into a multi-minute one (#258/#259), so the
# seed + top-up watchdog are copied verbatim rather than "simplified" for a
# probe script.

CAP          = Integer(ENV.fetch("WURK_BENCH_CAP", "20"))
REFILL_CHUNK = 25_000
SEED_CHUNKS  = 6
REFILL_FLOOR = 25_000
REFILL_POLL  = 0.05
EMPTY_POLL   = 0.05

SLOT_KEY = "bench:fetch_capped:slot"

# Throwaway prototype, not the shape lib/wurk/lua/queue_slot.lua will end up
# with (see header). KEYS = [slot_counter], ARGV = [cap]. Returns 1 acquired,
# 0 at capacity.
SLOT_ACQUIRE = <<~LUA
  local held = tonumber(redis.call("get", KEYS[1]) or "0")
  if held >= tonumber(ARGV[1]) then
    return 0
  end
  redis.call("incr", KEYS[1])
  redis.call("expire", KEYS[1], 30)
  return 1
LUA

# KEYS = [slot_counter]. Floors at zero rather than going negative, in case a
# release ever runs without a matching acquire (e.g. cap changed mid-run).
SLOT_RELEASE = <<~LUA
  local held = tonumber(redis.call("get", KEYS[1]) or "0")
  if held > 0 then
    redis.call("decr", KEYS[1])
  end
  return 1
LUA

class BenchJob
  include Wurk::Job

  def perform(*); end
end

config = Wurk::Configuration.new
config.logger = Logger.new(IO::NULL)
config.redis = { url: bench_redis_url("8") }
config.queues = %w[default]
config.fetch_poll_interval = EMPTY_POLL
capsule = config.default_capsule
capsule.prepare!

capsule.redis { |c| c.call("FLUSHDB") }
capsule.redis { |c| Wurk::Lua::Loader.script_load_all(c) }

acquire_sha = capsule.redis { |c| c.call("SCRIPT", "LOAD", SLOT_ACQUIRE) }
release_sha = capsule.redis { |c| c.call("SCRIPT", "LOAD", SLOT_RELEASE) }

client    = Wurk::Client.new(pool: capsule.redis_pool)
processor = Wurk::Processor.new(capsule)

chunk = { "class" => "BenchJob", "args" => Array.new(REFILL_CHUNK) { [] }, "queue" => "default" }

SEED_CHUNKS.times { client.push_bulk(chunk) }

stop = Queue.new
refiller = Thread.new do
  until stop.pop(timeout: REFILL_POLL)
    client.push_bulk(chunk) if capsule.redis { |c| c.call("LLEN", "queue:default") } < REFILL_FLOOR
  end
end

begin
  Benchmark.ips do |x|
    x.config(time: 5, warmup: 2)

    x.report("wurk fetch+execute (uncapped)") do
      processor.process_one
    end

    # Single-threaded here, so acquire/release around one process_one never
    # actually contends against CAP — this reports the round-trip overhead of
    # the gate, not its throttling behavior (that needs the multi-process
    # integration test slice 10 already scopes for itself).
    x.report("wurk fetch+execute (capped, prototype slot)") do
      acquired = capsule.redis { |c| c.call("EVALSHA", acquire_sha, 1, SLOT_KEY, CAP.to_s) }
      processor.process_one if acquired == 1
      capsule.redis { |c| c.call("EVALSHA", release_sha, 1, SLOT_KEY) }
    end
  end
ensure
  stop << :stop
  refiller.join
end

capsule.redis { |c| c.call("FLUSHDB") }
