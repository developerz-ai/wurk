# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Defined at the top level so Object.const_get(name) resolves the same way
# inside the forked child (which inherits the constant table but has no
# Minitest test-class lexical scope).
class ScheduledPromotionSentinelWorker
  include Wurk::Job

  def perform(redis_url, sentinel_key)
    client = RedisClient.config(url: redis_url).new_client
    ran_at = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
    client.call('HSET', sentinel_key, 'pid', ::Process.pid.to_s, 'ran_at', ran_at.to_s)
    client.call('EXPIRE', sentinel_key, 60)
  ensure
    client&.close
  end
end

# Scheduler Enq pointed at a per-test sorted set instead of the global
# `retry`/`schedule` keys. Plugged in via `config[:scheduled_enq]` (the
# documented seam) so this test's aggressively-polling Poller drains ONLY our
# namespaced set and can't steal other parallel tests' scheduled/retry jobs.
# Top-level so the forked child inherits the constant.
class NamespacedScheduledEnq < Wurk::Scheduled::Enq
  def enqueue_jobs(sorted_sets = nil)
    super(sorted_sets || @config[:scheduler_sets])
  end
end

# Real forks, real Redis, real perform. Issue #13 done-when: a job scheduled
# for `now + ~1s` is promoted off the schedule ZSET by the per-process Poller
# and actually RUNS within a few seconds of its target time.
#
# We shrink INITIAL_WAIT and the poll interval so the assertion is tight and
# the test is fast; the forked children inherit both (they copy the constant
# table + @config at fork). NEVER mock Redis here.
class ScheduledPromotionTest < Wurk::Test::UnitCase
  parallelize_me!

  REDIS_URL = ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
  POLL_TIMEOUT = 15.0
  POLL_INTERVAL = 0.1
  SCHEDULE_DELAY = 1.0
  # Generous ceiling: a sub-second poll cadence should beat this comfortably,
  # but CI schedulers are noisy and we'd rather not flake.
  MAX_LATENESS = 5.0

  def setup
    super
    @ns = "schedpromote-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @sentinel_key = "#{@ns}-sentinel"
    @schedule_set = "schedule-#{@ns}"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:timeout] = 5
    # Drain only our namespaced set, and do it near-immediately so the due
    # job promotes within a fraction of a second of becoming due.
    @config[:scheduled_enq] = NamespacedScheduledEnq
    @config[:scheduler_sets] = [@schedule_set]
    @config[:poll_interval_average] = 0.25
    # Near-zero first sweep so the due job promotes promptly. Config-scoped
    # (not a global-constant mutation) so it can't race other parallel tests'
    # pollers into draining the shared retry/schedule sets.
    @config[:scheduler_initial_wait] = 0.1
    @observer_pool = RedisClient.config(url: REDIS_URL).new_client
  end

  def teardown
    @observer_pool&.call('DEL', @sentinel_key, @schedule_set,
                         "queue:#{@queue_name}", private_queue_key(@queue_name))
    # Client#push (via promotion) registers the queue in the global `queues`
    # SET — drop it so it can't leak across parallel tests.
    @observer_pool&.call('SREM', 'queues', @queue_name)
    @observer_pool&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_due_scheduled_job_is_promoted_and_runs # rubocop:disable Metrics/AbcSize,Minitest/MultipleAssertions
    target_at = schedule_sentinel_job(SCHEDULE_DELAY)
    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: 5)
    swarm.boot(install_signals: false)
    supervisor = nil

    begin
      supervisor = Thread.new { swarm.supervise }
      result = wait_for_sentinel

      assert result, "sentinel #{@sentinel_key} never written within #{POLL_TIMEOUT}s — " \
                     'scheduled job was not promoted + run'
      refute_equal ::Process.pid.to_s, result['pid'],
                   'scheduled job should run in a forked child, not the test process'

      lateness = result['ran_at'].to_f - target_at

      assert_operator lateness, :>=, -0.5,
                      'job ran before its target time — promotion ignored the ZSET score'
      assert_operator lateness, :<=, MAX_LATENESS,
                      "job ran #{lateness.round(2)}s after target; expected within #{MAX_LATENESS}s"
    ensure
      swarm.shutdown(timeout: 5)
      supervisor&.join(10)
    end
  end

  private

  def topology_n(count)
    Wurk::Topology.flat(count: count, queues: [@queue_name], concurrency: 1)
  end

  # ZADDs a sentinel job to our namespaced schedule set with score `now +
  # delay`. Returns the absolute target epoch so the test can measure
  # promotion lateness.
  def schedule_sentinel_job(delay)
    target_at = ::Process.clock_gettime(::Process::CLOCK_REALTIME) + delay
    job = {
      'class' => ScheduledPromotionSentinelWorker.name,
      'args' => [REDIS_URL, @sentinel_key],
      'queue' => @queue_name,
      'jid' => SecureRandom.hex(12),
      'retry' => true
    }
    @observer_pool.call('ZADD', @schedule_set, target_at.to_s, Wurk.dump_json(job))
    target_at
  end

  def wait_for_sentinel
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      raw = @observer_pool.call('HGETALL', @sentinel_key)
      return normalize_hash(raw) unless raw.nil? || raw.empty?

      sleep POLL_INTERVAL
    end
    nil
  end

  # redis-client returns HGETALL as a Hash (RESP3) or a flat [k, v, …] array
  # (RESP2); normalize so callers can index fields by name.
  def normalize_hash(raw)
    raw.is_a?(::Array) ? ::Hash[*raw] : raw
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  def private_queue_key(queue_name)
    Wurk::Fetcher::Reliable.private_queue_name("queue:#{queue_name}")
  end
end
