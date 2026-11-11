# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# The poison decision on a reclaimed orphan has to be taken before the job is
# visible on its public queue. A worker parked in BLMOVE takes whatever lands on
# the queue the instant it lands, so a reaper that pushes first and counts
# second hands a poison job to a live worker and then kills the very same job
# into the dead set while it runs, death handlers and all.
#
# Real Redis, a real blocked consumer on its own connection. Never mock here.
#
# Spec: docs/target/sidekiq-pro.md §3.2, §12.
class ReaperPoisonRaceTest < Wurk::Test::UnitCase
  parallelize_me!

  DEAD_PID = 999_999
  CONSUMER = 'reaper-poison-race-consumer'
  THRESHOLD = Wurk::Middleware::PoisonPill::RECOVERY_THRESHOLD

  def setup
    super
    @ns = "poisonrace-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @public_queue = Wurk::Keys.queue(@queue_name)
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config.default_capsule.queues = [@queue_name]
    @reaper = Wurk::Fetcher::Reaper.new(@config, grace: 0)
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
    @deaths = []
    @death_handler = ->(job, ex) { @deaths << [job['jid'], ex.class] }
    Wurk.configuration.death_handlers << @death_handler
  end

  def teardown
    Wurk.configuration.death_handlers.delete(@death_handler)
    @consumer&.kill
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_a_poison_job_is_never_handed_to_a_parked_worker
    jid = SecureRandom.hex(12)
    job = orphan(jid, prior_recoveries: THRESHOLD)
    park_consumer

    assert_equal 1, @reaper.reclaim!

    assert_nil @consumer.value, 'the parked worker must never receive a job being killed'
    assert_equal [job], @observer.call('ZRANGE', Wurk::Keys::DEAD, 0, -1), 'dead-set exactly once'
    assert_equal [[jid, Wurk::Middleware::PoisonPill::Poisoned]], @deaths, 'death handlers fire once'
    assert_equal 0, @observer.call('LLEN', private_list)
    assert_equal 0, @observer.call('LLEN', @public_queue)
  end

  def test_a_recoverable_job_reaches_the_parked_worker_once
    jid = SecureRandom.hex(12)
    job = orphan(jid, prior_recoveries: THRESHOLD - 1)
    park_consumer

    assert_equal 1, @reaper.reclaim!

    assert_equal job, @consumer.value
    assert_equal 0, @observer.call('ZCARD', Wurk::Keys::DEAD)
    assert_empty @deaths
    assert_equal THRESHOLD, Wurk::Middleware::PoisonPill.recovery_count(jid)
    assert_equal 0, @observer.call('LLEN', private_list)
  end

  private

  def orphan(jid, prior_recoveries:)
    job = Wurk.dump_json('class' => 'PoisonRaceJob', 'args' => [], 'queue' => @queue_name, 'jid' => jid)
    @observer.call('SET', Wurk::Middleware::PoisonPill.counter_key(jid), prior_recoveries) if prior_recoveries.positive?
    @observer.call('RPUSH', private_list, job)
    job
  end

  def private_list
    "#{@public_queue}|#{Wurk::Component.hostname}|#{DEAD_PID}|#{Wurk::Component::PROCESS_NONCE}|0"
  end

  # A worker blocked on the public queue the way Fetcher::Reliable parks on an
  # empty poll. Its value is the job it took, nil when none arrived in time.
  def park_consumer
    @consumer = Thread.new do
      conn = RedisClient.config(url: Wurk::Test.redis_url, read_timeout: 5).new_client
      conn.call('CLIENT', 'SETNAME', CONSUMER)
      conn.call('BLMOVE', @public_queue, "#{@ns}-taken", 'RIGHT', 'LEFT', 1)
    ensure
      conn&.close
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep(0.005) until parked? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    assert_predicate self, :parked?, 'the consumer never parked in BLMOVE'
  end

  def parked?
    @observer.call('CLIENT', 'LIST').to_s.lines.any? { |l| l.include?("name=#{CONSUMER} ") && l.include?('cmd=blmove') }
  end
end
