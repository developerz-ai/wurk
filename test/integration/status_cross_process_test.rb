# frozen_string_literal: true

require_relative '../test_helper'
require 'securerandom'

# Top-level so Object.const_get(name) resolves inside the forked child (which
# inherits the constant table but has no Minitest test-class lexical scope).
#
# Blocks mid-`perform` until the test process flips a release flag, so there
# is a real, observable window in which the job is `running` in a DIFFERENT
# OS process than the one reading `Wurk::Status.get(jid)`.
class StatusCrossProcessWorker
  include Wurk::Job

  sidekiq_options track: true

  POLL_INTERVAL = 0.05

  def perform(redis_url, sentinel_key, release_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', sentinel_key, ::Process.pid.to_s, 'EX', 60)
    status&.at(1, 2, 'halfway')

    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 20
    sleep POLL_INTERVAL until client.call('EXISTS', release_key) == 1 ||
                              ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

    { 'ran_in_pid' => ::Process.pid }
  ensure
    client&.close
  end
end

# Real forks, real Redis, real perform. #06 done-when: a tracked job's status
# is readable from a process other than the one that ran it, while it is still
# running — not just after it finishes. NEVER mock Redis here.
class StatusCrossProcessTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 20.0
  POLL_INTERVAL = 0.1

  def setup
    super
    @ns = "statusxp-#{::Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @sentinel_key = "#{@ns}-sentinel"
    @release_key = "#{@ns}-release"
    @config = build_config
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer&.call('UNLINK', @sentinel_key, @release_key, "queue:#{@queue_name}",
                    private_queue_key(@queue_name))
    @observer&.call('SREM', 'queues', @queue_name)
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_status_is_readable_from_another_process_while_the_job_is_still_running
    jid = Wurk::Client.push('class' => StatusCrossProcessWorker.name,
                            'args' => [Wurk::Test.redis_url, @sentinel_key, @release_key],
                            'queue' => @queue_name, 'track' => true)

    assert_equal 'enqueued', Wurk::Status.get(jid)&.state, 'the client push must write the enqueued row itself'

    swarm = Wurk::Swarm.new(topology: topology_n(1), config: @config, shutdown_timeout: 5)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      child_pid = wait_for_sentinel

      refute_nil child_pid, "worker never wrote #{@sentinel_key} within #{POLL_TIMEOUT}s"
      refute_equal ::Process.pid.to_s, child_pid, 'the job must run in a forked child, not the test process'

      assert_running_mid_execution(jid)

      @observer.call('SET', @release_key, '1', 'EX', 60)

      assert_completed_with_result(jid, child_pid)
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

  def assert_running_mid_execution(jid)
    running = wait_for_state(jid, 'running')

    refute_nil running, 'status row never reached running while the job was mid-execution'
    assert_equal 'running', running.state
    assert_equal @queue_name, running.queue
    assert_equal StatusCrossProcessWorker.name, running.job_class
    assert_operator running.started_at, :>, 0
    assert_equal 1, running.progress, 'the in-job progress report must be visible mid-run, from this process'
    assert_equal 'halfway', running.message
  end

  def assert_completed_with_result(jid, child_pid)
    completed = wait_for_state(jid, 'complete')

    refute_nil completed, 'status row never reached complete after release'
    assert_equal({ 'ran_in_pid' => child_pid.to_i }, completed.result)
    assert_operator completed.finished_at, :>=, completed.started_at
  end

  def topology_n(count)
    Wurk::Topology.flat(count: count, queues: [@queue_name], concurrency: 1)
  end

  def build_config
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:timeout] = 5
    # A fresh Configuration starts with an empty server chain (require-time
    # registrations only touch the global Wurk.configuration) — without this,
    # the row would stay `enqueued` forever; nothing would ever write `running`.
    config.server_middleware.add(Wurk::Middleware::Status)
    config
  end

  def wait_for_sentinel
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      pid = @observer.call('GET', @sentinel_key)
      return pid if pid

      sleep POLL_INTERVAL
    end
    nil
  end

  # Reads through Wurk::Status (a fresh connection from Wurk.redis_pool in
  # THIS process), never through @observer's raw HGETALL — the point of the
  # test is that the public read API works cross-process, not just Redis.
  def wait_for_state(jid, state)
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      record = Wurk::Status.get(jid)
      return record if record&.state == state

      sleep POLL_INTERVAL
    end
    nil
  end

  def monotonic_now = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)

  def private_queue_key(queue_name)
    Wurk::Fetcher::Reliable.private_queue_name("queue:#{queue_name}")
  end
end
