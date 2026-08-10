# frozen_string_literal: true

require_relative '../test_helper'

# Top-level so forked children (which inherit the constant table but not the
# test's lexical scope) can resolve these by name — same reason
# ReaperKill9Worker in reaper_kill9_test.rb is top-level.

# Bumps a running-count/high-water-mark pair and counts how many times the
# configured cap was actually reached, so a test can tell "never breached the
# cap" apart from "never even got close to it" — the difference between a
# real gate and a vacuously passing one.
GLOBAL_CONCURRENCY_BUMP_SCRIPT = <<~LUA
  local n = redis.call('INCR', KEYS[1])
  local max = tonumber(redis.call('GET', KEYS[2]) or '0')
  if n > max then redis.call('SET', KEYS[2], n) end
  if n == tonumber(ARGV[1]) then redis.call('INCR', KEYS[3]) end
  return n
LUA

# Holds a global-concurrency slot for `sleep_for` seconds while recording a
# high-water mark of concurrent holders, cluster-wide.
class GlobalConcurrencyCapWorker
  include Wurk::Job

  def perform(redis_url, keys)
    client = RedisClient.config(url: redis_url).new_client
    client.call('EVAL', GLOBAL_CONCURRENCY_BUMP_SCRIPT, 3,
                keys['running'], keys['max'], keys['at_cap'], keys['cap'])
    sleep keys['sleep_for']
    client.call('DECR', keys['running'])
    client.call('INCR', keys['done'])
  ensure
    client&.close
  end
end

# A trivial, fast job — for the fairness and leak tests, where the point is
# whether a job ran at all (or how many did), not how long it held its slot.
class GlobalConcurrencyDoneWorker
  include Wurk::Job

  def perform(redis_url, done_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('INCR', done_key)
  ensure
    client&.close
  end
end

# Counts its own starts, then sleeps far longer than this test ever waits —
# long enough that a `kill -9` always lands while it still holds its slot. The
# counter (not a flag) is what lets the SIGKILL test observe the swarm's own
# replacement worker resuming the job on its own, with no operator action.
class GlobalConcurrencySleeperWorker
  include Wurk::Job

  def perform(redis_url, started_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('INCR', started_key)
    client.close
    sleep 300
  end
end

# Real forks, real Redis, real `kill -9` — the integration proof for global
# per-queue concurrency (`10-global-concurrency.md` "Tests"). The unit and
# lifecycle suites (`fetcher_capped_test.rb`, `queue_slot_lifecycle_test.rb`)
# already pin the Lua script and the release/refresh/quiet paths in isolation;
# this file is the same claims proven across real processes, which is the only
# place a cluster-wide cap actually has to hold.
#
# Every assertion here runs *before* `swarm.shutdown` (inside `with_swarm`'s
# block), never after: a swarm child's own clean exit (`ChildBoot#run`'s
# `exit 0`) is a `SystemExit`, and a child forked mid-test inherits this
# process's `minitest/autorun` `at_exit` hook along with everything else —
# letting that exit unwind past shutdown re-enters Minitest inside the exiting
# child. Reading Redis state after `shutdown` races that re-entrant run.
# Asserting only while the swarm is still up (the pattern every other
# real-fork test in this suite already follows) sidesteps it entirely.
#
# NEVER mock Redis. Parallel safety: every queue, slot key and counter is
# namespaced per test.
class GlobalConcurrencyTest < Wurk::Test::UnitCase
  parallelize_me!

  # Wall-clock budget for the 10k-job drain below. It is a HANG DETECTOR, not a
  # throughput assertion — `bench/` owns throughput, and this test's actual
  # claim is "no slot holders leaked once the queue is empty".
  #
  # `wait_for` returns the instant the condition holds, so a generous budget
  # costs a healthy run nothing and only buys a loaded one room — which is why
  # it is deliberately far above the ~20s this drain actually takes on an idle
  # machine. It also scales with the parallel worker count, since the test boots
  # a 4-child swarm (20 threads) while every other minitest-parallel_fork worker
  # is running something of its own.
  DRAIN_BUDGET = 60 * Integer(ENV.fetch('NCPU', 4)).clamp(4, 14)

  def setup
    super
    @ns = "gc-#{Process.pid}-#{object_id}"
    @pool = Wurk::RedisPool.new(size: 10, url: Wurk::Test.redis_url, timeout: 5, name: "gc-#{object_id}")
  end

  def teardown
    @pool&.disconnect!
    super
  end

  # 4 processes x 5 threads = 20 competing threads against a cap of 3: never
  # more than 3 in flight cluster-wide, and sustained — the cap is hit
  # repeatedly over the run, not once by luck.
  def test_a_cluster_wide_cap_holds_across_many_processes_and_threads
    cap = 3
    job_count = 240
    queue = "#{@ns}-cap"
    keys = concurrency_keys(queue)
    config = build_config(queue => cap)
    push_cap_jobs(queue, job_count, cap, keys, sleep_for: 0.1)

    with_swarm(config, Wurk::Topology.flat(count: 4, queues: [queue], concurrency: 5)) do
      assert wait_for(60) { done_count(keys) >= job_count },
             "only #{done_count(keys)}/#{job_count} jobs finished within 60s"

      assert_operator max_seen(keys), :<=, cap, "saw more than #{cap} jobs in flight at once"
      assert_operator at_cap_count(keys), :>=, 20,
                      'the cap was not sustained — expected it to be hit repeatedly, not once'
    end
  ensure
    cleanup_queue(queue)
    @pool.with { |c| c.call('DEL', keys.values) } if keys
  end

  # A holder that never releases (SIGKILLed mid-job) must not strand capacity
  # forever: the next claim reclaims it once the TTL has elapsed, with no
  # operator action — no manual sweep, just the normal slot script.
  #
  # The swarm's own crash-respawn keeps the killed slot's queue assignment, so
  # its replacement child is left fetching against the very capacity its
  # predecessor still (briefly) holds. Proving *that* worker resumes on its
  # own — not a synthetic probe token racing it for the same one slot — is the
  # actual end-to-end shape of "no operator action". SIGKILL never runs Ruby's
  # exit path, so this test carries none of the shutdown-ordering risk the
  # class comment describes.
  def test_a_sigkilled_slot_holder_recovers_its_capacity_within_the_ttl
    queue = "#{@ns}-kill9"
    started_key = "#{@ns}-started"
    config = build_config(queue => 1)
    push(queue, GlobalConcurrencySleeperWorker, [Wurk::Test.redis_url, started_key])
    elapsed = nil

    with_swarm(config, Wurk::Topology.flat(count: 1, queues: [queue], concurrency: 1)) do |swarm|
      assert wait_for(15) { started_count(started_key) >= 1 },
             'the sleeper never started — never took the slot to begin with'
      assert_equal 1, slot_count(queue), 'the job must hold the slot while it runs'

      hold_taken_at = monotonic
      ::Process.kill('KILL', swarm.children.keys.first)
      recovered = wait_for(Wurk::QueueSlot::TTL_SECONDS + 30) { started_count(started_key) >= 2 }
      elapsed = monotonic - hold_taken_at

      assert recovered, 'the replacement worker never resumed — capacity never recovered ' \
                        "(started #{started_count(started_key)} time(s))"
      assert_operator elapsed, :>=, Wurk::QueueSlot::TTL_SECONDS - 10,
                      'recovered suspiciously fast — the TTL should have to actually elapse'
    end
  ensure
    cleanup_queue(queue)
    @pool.with { |c| c.call('DEL', started_key) }
  end

  # The hard part of the slice, proven with real processes rather than a
  # stubbed fetcher: a queue sitting at capacity must not stall a sibling
  # queue served by the very same worker fleet.
  def test_a_capped_queue_at_capacity_does_not_stall_a_sibling_queue
    open_jobs = 50
    cap_queue = "#{@ns}-full"
    open_queue = "#{@ns}-open"
    cap_done = "#{@ns}-cap-done"
    open_done = "#{@ns}-open-done"
    config = build_config(cap_queue => 1)

    # Exhaust the only slot before any worker boots — this queue can never
    # admit a job for the length of the test.
    assert Wurk::QueueSlot.acquire(cap_queue, capacity: 1, token: "#{@ns}-external", pool: @pool)
    push(cap_queue, GlobalConcurrencyDoneWorker, [Wurk::Test.redis_url, cap_done])
    push_bulk(open_queue, GlobalConcurrencyDoneWorker, Array.new(open_jobs) { [Wurk::Test.redis_url, open_done] })

    with_swarm(config, Wurk::Topology.flat(count: 2, queues: [cap_queue, open_queue], concurrency: 3)) do
      assert wait_for(20) { @pool.with { |c| c.call('GET', open_done) }.to_i >= open_jobs },
             'the sibling queue stalled behind the full one'

      assert_equal 0, @pool.with { |c| c.call('GET', cap_done) }.to_i, 'the capped job must never have run'
      assert_equal 1, @pool.with { |c| c.call('LLEN', Wurk::Keys.queue(cap_queue)) },
                   'the capped job stays queued, never claimed'
    end
  ensure
    Wurk::QueueSlot.release(cap_queue, token: "#{@ns}-external", pool: @pool)
    cleanup_queue(cap_queue)
    cleanup_queue(open_queue)
    @pool.with { |c| c.call('DEL', cap_done, open_done) }
  end

  # 10k jobs through a capped queue must leave nothing behind: every hold this
  # test ever took is released on the way out, so the slot ZSET is back to
  # empty once the last job finishes and its release has had a moment to ride
  # the next fetch's pipeline — every path that goes idle flushes it, so the
  # swarm never has to be stopped to observe the drain.
  def test_10k_jobs_through_a_capped_queue_leave_the_slot_key_empty
    job_count = 10_000
    queue = "#{@ns}-leak"
    done_key = "#{@ns}-leak-done"
    config = build_config(queue => 5)
    push_bulk(queue, GlobalConcurrencyDoneWorker, Array.new(job_count) { [Wurk::Test.redis_url, done_key] })

    with_swarm(config, Wurk::Topology.flat(count: 4, queues: [queue], concurrency: 5)) do
      assert wait_for(DRAIN_BUDGET) { @pool.with { |c| c.call('GET', done_key) }.to_i >= job_count },
             "only #{@pool.with { |c| c.call('GET', done_key) }}/#{job_count} jobs finished in #{DRAIN_BUDGET}s"

      assert wait_for(10) { slot_count(queue).zero? }, "#{slot_count(queue)} slot holders leaked after full drain"
    end
  ensure
    cleanup_queue(queue)
    @pool.with { |c| c.call('DEL', done_key) }
  end

  private

  def build_config(caps)
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:fetch_poll_interval] = 0.5
    # The unconditional boot-time reclaim sweep (`Launcher#boot_reclaim`)
    # already recovers a killed holder's stranded private-list job the moment
    # its replacement child starts — that part isn't configurable, and the
    # SIGKILL test below relies on it. This only silences the *periodic*
    # reaper (job-recovery, not slot-recovery — a separate concern covered by
    # reaper_kill9_test.rb) so its 60s cadence can't add noise across the
    # longer-running tests in this file.
    config[:super_fetch_reaper_interval] = 3600
    config.global_concurrency = caps
    config
  end

  # Boots a swarm, yields for the caller's own wait/assertions, then always
  # shuts it down — the pattern every real-fork test in this suite uses
  # (`stop_supervisor_thread`, `SwarmTeardown`) so a failed assertion never
  # leaves a supervisor thread respawning children into a later test. The
  # caller's block must do all of its own asserting before returning — see the
  # class comment on why nothing here reads Redis state once this returns.
  def with_swarm(config, topology)
    swarm = Wurk::Swarm.new(topology: topology, config: config, shutdown_timeout: 5)
    supervisor = nil
    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }
      yield swarm
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 15)
    end
  end

  def concurrency_keys(queue)
    { running: "#{queue}-running", max: "#{queue}-max", at_cap: "#{queue}-at-cap", done: "#{queue}-done" }
  end

  def push_cap_jobs(queue, count, cap, keys, sleep_for:)
    job_keys = { 'running' => keys[:running], 'max' => keys[:max], 'at_cap' => keys[:at_cap],
                 'cap' => cap, 'done' => keys[:done], 'sleep_for' => sleep_for }
    args = Array.new(count) { [Wurk::Test.redis_url, job_keys] }
    push_bulk(queue, GlobalConcurrencyCapWorker, args)
  end

  def push(queue, klass, args)
    Wurk::Client.new(pool: @pool).push('class' => klass.name, 'args' => args, 'queue' => queue)
  end

  def push_bulk(queue, klass, args)
    Wurk::Client.new(pool: @pool).push_bulk('class' => klass.name, 'args' => args, 'queue' => queue)
  end

  def done_count(keys) = @pool.with { |c| c.call('GET', keys[:done]) }.to_i

  def max_seen(keys) = @pool.with { |c| c.call('GET', keys[:max]) }.to_i

  def at_cap_count(keys) = @pool.with { |c| c.call('GET', keys[:at_cap]) }.to_i

  def slot_count(queue) = @pool.with { |c| c.call('ZCARD', Wurk::Keys.queue_slot(queue)) }

  def started_count(started_key) = @pool.with { |c| c.call('GET', started_key) }.to_i

  def wait_for(timeout)
    deadline = monotonic + timeout
    loop do
      result = yield
      return result if result
      return false if monotonic >= deadline

      sleep 0.1
    end
  end

  def monotonic = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

  def cleanup_queue(queue)
    public_q = Wurk::Keys.queue(queue)
    @pool.with do |conn|
      keys = conn.call('KEYS', "#{public_q}|*")
      conn.call('DEL', public_q, Wurk::Keys.queue_slot(queue), *keys)
    end
  rescue StandardError
    nil
  end
end
