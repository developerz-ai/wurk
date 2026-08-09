# frozen_string_literal: true

require 'benchmark/ips'
require 'logger'
require 'wurk'
require_relative 'support'

# Step 1 of docs/plans/2026/08/07/101-beyond-sidekiq/10-global-concurrency.md:
# "Measure first... so the cost is known, not argued." Written before slice 10
# landed — no `lib/wurk/fetcher/capped.rb` gate, no config option, no
# `lib/wurk/lua/queue_slot.lua` — so this is NOT a preview of the real
# integration, and it was not re-pointed at one when the real gate shipped: the
# shape it prices is the one that measurement rejected. It is a standalone
# probe: the REAL fetch+execute path (identical to bench/fetch_execute.rb)
# reported once uncapped and once wrapped in a throwaway acquire/release Lua
# pair — SCRIPT LOADed at boot and called with EVALSHA, like every other script
# here, but outside lib/wurk/lua.rb's registry — to put a number on "one extra
# atomic Redis round-trip either side of a fetch" before slice 10 argued about
# it in review.
#
# The slot script below is the cheapest correct-ish shape a cap COULD take — a
# bare counter with a TTL safety net — and is not what slice 10 shipped. What
# shipped is a TTL'd holder per slot (lib/wurk/lua/queue_slot.lua), refreshed by
# the heartbeat, and the claim folded INTO the fetch rather than bracketing it
# (lib/wurk/lua/fetch_slot.lua) — precisely because of the number below. So this
# is an upper bound on the shipped cost and nothing more precise; don't read it
# past "roughly what a single extra round trip costs here".
#
# Excluded from `rake bench` (Rakefile UNGATED_SCRIPTS): it measures a shape
# nothing in lib/ has, so there is nothing here to regress. Run it explicitly
# via `rake bench:fetch_capped`. The unconfigured floor slice 10 IS gated on is
# bench/command_count.rb (`rake bench:command_count_cap_off`).
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

CAP          = Integer(ENV.fetch('WURK_BENCH_CAP', '20'))
REFILL_CHUNK = 25_000
SEED_CHUNKS  = 6
REFILL_FLOOR = 25_000
REFILL_POLL  = 0.05
EMPTY_POLL   = 0.05

SLOT_KEY = 'bench:fetch_capped:slot'

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
config.redis = { url: bench_redis_url('8') }
config.queues = %w[default]
config.fetch_poll_interval = EMPTY_POLL
capsule = config.default_capsule
capsule.prepare!

capsule.redis { |c| c.call('FLUSHDB') }
capsule.redis { |c| Wurk::Lua::Loader.script_load_all(c) }

acquire_sha = capsule.redis { |c| c.call('SCRIPT', 'LOAD', SLOT_ACQUIRE) }
release_sha = capsule.redis { |c| c.call('SCRIPT', 'LOAD', SLOT_RELEASE) }

client    = Wurk::Client.new(pool: capsule.redis_pool)
processor = Wurk::Processor.new(capsule)

chunk = { 'class' => 'BenchJob', 'args' => Array.new(REFILL_CHUNK) { [] }, 'queue' => 'default' }

SEED_CHUNKS.times { client.push_bulk(chunk) }

stop = Queue.new
refiller = Thread.new do
  until stop.pop(timeout: REFILL_POLL)
    client.push_bulk(chunk) if capsule.redis { |c| c.call('LLEN', 'queue:default') } < REFILL_FLOOR
  end
end

begin
  Benchmark.ips do |x|
    x.config(time: 5, warmup: 2)

    x.report('wurk fetch+execute (uncapped)') do
      processor.process_one
    end

    # Single-threaded here, so acquire/release around one process_one never
    # actually contends against CAP — this reports the round-trip overhead of
    # the gate, not its throttling behavior (that needs the multi-process
    # integration test slice 10 already scopes for itself).
    x.report('wurk fetch+execute (capped, prototype slot)') do
      acquired = capsule.redis { |c| c.call('EVALSHA', acquire_sha, 1, SLOT_KEY, CAP.to_s) }
      # A failed acquire holds no slot, so releasing would decrement whatever
      # other holder is at the cap — release only what this iteration took.
      next unless acquired == 1

      begin
        processor.process_one
      ensure
        capsule.redis { |c| c.call('EVALSHA', release_sha, 1, SLOT_KEY) }
      end
    end
  end
ensure
  stop << :stop
  refiller.join
  capsule.redis { |c| c.call('FLUSHDB') }
end
