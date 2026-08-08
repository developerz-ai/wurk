# frozen_string_literal: true

require_relative '../test_helper'

# Top-level so the forked child resolves the constant — children inherit the
# constant table but not the Minitest test-class lexical scope.
class PeriodicLeaderWorker
  include Wurk::Job

  def perform; end
end

# Real forks, real Redis, real leader election. Issue #14 done-when: with two
# worker processes and one registered loop, the loop fires EXACTLY ONCE per
# tick — the single cluster-leader invariant gates periodic enqueues so a
# follower never double-enqueues. We assert on the loop's fire history (one
# audit entry per enqueue, written only by the enqueuing leader).
#
# Isolation: the whole swarm runs against a DEDICATED Redis DB. A wired cron
# poller becomes the cluster leader and would otherwise fire *every* loop in
# the shared `periodic` set (flaking parallel unit tests). A private DB scopes
# the leader lock, periodic set, queue, and history to this test alone.
# NEVER mock Redis here.
class PeriodicLeaderTest < Wurk::Test::UnitCase
  parallelize_me!

  # Ceiling only — wait_for_history returns the instant the loop fires, so a
  # generous timeout costs nothing on the happy path and just absorbs the slow
  # tail: under a loaded CI runner, forking + booting two swarm children and
  # settling leader election can take well over 20s, which is what flaked #73.
  POLL_TIMEOUT = 45.0
  POLL_INTERVAL = 0.1

  def setup
    super
    @ns = "periodic-leader-#{Process.pid}-#{object_id}"
    @queue = "#{@ns}-q"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.redis = { url: Wurk::Test.redis_url }
    @config[:timeout] = 5
    # Tick fast so the due loop fires within the test window instead of after a
    # full minute; campaign/renew aggressively so a leader settles quickly.
    @config[:cron_tick_interval] = 0.2
    @config[:leader_ttl] = 3
    @config[:leader_renew_interval] = 0.5
    @config[:leader_follower_interval] = 0.5
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @observer.call('DEL', Wurk::Leader::DEFAULT_KEY)
    @lid = nil
  end

  def teardown
    if @lid
      @observer.call('SREM', Wurk::Cron::PERIODIC_KEY, @lid)
      @observer.call('DEL', "#{Wurk::Cron::LOOP_PREFIX}#{@lid}", "#{Wurk::Cron::HISTORY_PREFIX}#{@lid}")
    end
    @observer.call('DEL', Wurk::Leader::DEFAULT_KEY, "queue:#{@queue}")
    @observer.call('SREM', 'queues', @queue)
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_two_workers_fire_one_loop_exactly_once
    @lid = register_loop

    swarm = Wurk::Swarm.new(topology: topology_n(2), config: @config, shutdown_timeout: 5)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      assert wait_for_history, "loop #{@lid} never fired within #{POLL_TIMEOUT}s — " \
                               'the leader cron poller is not enqueuing'
      assert_equal 1, history_len,
                   'two workers + one loop must enqueue exactly once per tick (no follower double-fire)'
    ensure
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
    end
  end

  private

  def topology_n(count)
    Wurk::Topology.flat(count: count, queues: [@queue], concurrency: 1)
  end

  # Persist the loop straight through the observer client (db-isolated), so the
  # parent never opens the global pool that the forked children would inherit.
  # Seed `nf` (next-fire) to one second ago so the loop is due on the leader's
  # very first tick — deterministic, no waiting on the next wall-clock minute.
  def register_loop
    lp = Wurk::Cron::Loop.new(
      schedule: '* * * * *', klass: PeriodicLeaderWorker.name, options: { 'queue' => @queue }
    )
    @observer.call('SADD', Wurk::Cron::PERIODIC_KEY, lp.lid)
    @observer.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lp.lid}",
                   *lp.to_redis_hash.flatten, 'nf', (Time.now.to_i - 1).to_s)
    lp.lid
  end

  def history_len
    @observer.call('LLEN', "#{Wurk::Cron::HISTORY_PREFIX}#{@lid}").to_i
  end

  def wait_for_history # rubocop:disable Naming/PredicateMethod
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      return true if history_len >= 1

      sleep POLL_INTERVAL
    end
    false
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
