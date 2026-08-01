# frozen_string_literal: true

require "benchmark/ips"
require "logger"
require "wurk"
require_relative "support"

# Gate: >5% regression vs main blocks merge.
#
# Idle scheduler overhead (#13 done-when: poller adds <1% at idle). Each poll
# sweep runs one atomic zpopbyscore per set (retry + schedule); when both are
# empty the sweep is two EVALSHA round-trips that return nil and re-push
# nothing. This measures that idle sweep — the work the per-process Poller
# repeats on every wake when there's nothing due.
#
# Runs on a dedicated Redis logical DB (default 12) so this bench's DEL of
# schedule/retry can never wipe a dev's real DB 0 data (#258/#259).

config = Wurk::Configuration.new
config.logger = Logger.new(IO::NULL)
config.redis = { url: bench_redis_url("12") }
pool = config.default_capsule.redis_pool
pool.with { |c| Wurk::Lua::Loader.script_load_all(c) }

# Empty both sets so every sweep exercises the idle (nothing-due) path.
pool.with { |c| c.call("DEL", "schedule", "retry") }

enq = Wurk::Scheduled::Enq.new(config)

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)

  x.report("wurk idle scheduler sweep") do
    enq.enqueue_jobs
  end
end

pool.with { |c| c.call("DEL", "schedule", "retry") }
