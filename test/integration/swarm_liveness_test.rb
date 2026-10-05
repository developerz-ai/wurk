# frozen_string_literal: true

require_relative '../test_helper'

# Real forks, real Redis, real signals: the supervisor replaces a child whose
# heartbeat stopped moving while its pid stayed alive. NEVER mock Redis here.
#
# Each case runs at the smallest timeout Liveness accepts (MIN_TIMEOUT, two
# beat intervals), so it takes roughly that long plus a check interval.
class SwarmLivenessIntegrationTest < Wurk::Test::UnitCase
  parallelize_me!

  SHUTDOWN_TIMEOUT = 1
  TIMEOUT = Wurk::Swarm::Liveness::MIN_TIMEOUT
  POLL_INTERVAL = 0.2

  # Runs inside the swarm child: kills that child's heartbeat thread and leaves
  # everything else (fetch, signal dispatch) running — a process that is alive
  # but no longer saying so.
  class StopHeartbeatJob
    include Wurk::Job

    def perform(url, key)
      ::Thread.list.each { |t| t.kill if t.name == 'heartbeat' }
      client = RedisClient.config(url: url).new_client
      client.call('RPUSH', key, ::Process.pid.to_s)
      client.close
    end
  end

  def setup
    super
    @ns = "liveness-#{::Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @log = StringIO.new
    @log_lock = Mutex.new
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(SyncIO.new(@log, @log_lock))
    @config.redis = { url: Wurk::Test.redis_url }
    @config[:timeout] = SHUTDOWN_TIMEOUT
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  # Only the parent's writes matter here — a forked child's copy of the IO is
  # its own.
  class SyncIO
    def initialize(target, lock)
      @io = target
      @lock = lock
    end

    def write(*args) = @lock.synchronize { @io.write(*args) }
    def close = nil
  end

  def test_child_with_stopped_heartbeat_is_termed_and_respawned
    with_swarm do |swarm, original|
      key = "#{@ns}-stopped"
      push_job(StopHeartbeatJob, Wurk::Test.redis_url, key)

      assert_equal original.to_s, @observer.call('BLPOP', key, 30)&.last, 'the job never ran in the child'

      replacement = wait_for(TIMEOUT * 3) { (swarm.children.keys - [original]).first }

      assert replacement, "child #{original} with a dead heartbeat was never replaced"
      assert wait_for(10) { !pid_alive?(original) }, 'the stale child must be gone'
      assert_match(/child #{original} heartbeat stale .*sending TERM/, log)
      assert_match(/unresponsive child #{original} exited/, log)
      refute_match(/sending KILL/, log, 'a child that honors TERM is not KILLed')
    end
  end

  # SIGSTOP freezes the whole child — heartbeat and TERM handling alike — so
  # the TERM stays pending and only the escalation can free the slot.
  def test_child_that_ignores_term_is_killed_after_the_drain_budget
    with_swarm do |swarm, original|
      ::Process.kill('STOP', original)
      budget = TIMEOUT + Wurk::Swarm::Liveness::CHECK_INTERVAL + SHUTDOWN_TIMEOUT + Wurk::Swarm::SHUTDOWN_GRACE

      replacement = wait_for(budget * 2) { (swarm.children.keys - [original]).first }

      assert replacement, "stopped child #{original} was never replaced"
      assert_match(/child #{original} heartbeat stale .*sending TERM/, log)
      assert_match(/child #{original} still running .*sending KILL/, log)
    ensure
      ::Process.kill('KILL', original) if original && pid_alive?(original)
    end
  end

  private

  def with_swarm
    swarm = Wurk::Swarm.new(topology: Wurk::Topology.flat(count: 1, queues: [@queue_name], concurrency: 1),
                            config: @config, shutdown_timeout: SHUTDOWN_TIMEOUT, heartbeat_timeout: TIMEOUT)
    supervisor = nil
    original = swarm.boot(install_signals: false).first
    supervisor = Thread.new { swarm.supervise }

    assert wait_for(30) { beat_seen?(original) }, 'child never wrote its first heartbeat'
    yield swarm, original
  ensure
    begin
      swarm&.shutdown(timeout: SHUTDOWN_TIMEOUT)
    rescue StandardError
      nil
    end
    stop_supervisor_thread(supervisor, 15) if supervisor
    @observer.call('DEL', "queue:#{@queue_name}")
  end

  def beat_seen?(pid)
    @observer.call('SISMEMBER', 'processes',
                   "#{Wurk::Component.hostname}:#{pid}:#{Wurk::Component::PROCESS_NONCE}") == 1
  end

  def push_job(klass, *args)
    job = { 'class' => klass.name, 'args' => args, 'queue' => @queue_name, 'jid' => SecureRandom.hex(12),
            'retry' => false, 'created_at' => Time.now.to_f, 'enqueued_at' => Time.now.to_f }
    @observer.call('SADD', 'queues', @queue_name)
    @observer.call('LPUSH', "queue:#{@queue_name}", Wurk.dump_json(job))
  end

  def wait_for(timeout)
    deadline = monotonic_now + timeout
    loop do
      value = yield
      return value if value
      return nil if monotonic_now > deadline

      sleep POLL_INTERVAL
    end
  end

  def log
    @log_lock.synchronize { @log.string.dup }
  end

  def pid_alive?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
