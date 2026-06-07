# frozen_string_literal: true

require_relative '../test_helper'

# Top-level so the constant resolves identically in the forked swarm child
# (Object inherits via fork; lexically nested classes don't round-trip).
#
# An IterableJob that interrupts itself on its first run, then completes on the
# re-pushed run. The "armed" flag is consumed (DEL) the first time through, so
# the second pass — after InterruptHandler re-pushes the job to the queue head —
# falls through and writes the done key. No `cancel!`: cancellation is sticky
# per-jid and would loop forever, whereas a one-shot raise models exactly the
# interrupt → re-push → resume flow we want to observe.
class InterruptRepushIterableWorker
  include Wurk::IterableJob

  def build_enumerator(*_args, cursor:)
    start = cursor || 0
    Enumerator.new { |y| start.upto(0) { |i| y << [i, i + 1] } }
  end

  def each_iteration(_item, redis_url, armed_key, done_key)
    client = RedisClient.config(url: redis_url).new_client
    if client.call('GET', armed_key)
      client.call('DEL', armed_key)
      raise Wurk::Job::Interrupted
    end
    client.call('SET', done_key, ::Process.pid.to_s)
    client.call('EXPIRE', done_key, 60)
  ensure
    client&.close
  end
end

# Real fork, real Redis, no mocking. Boots a swarm child that processes a single
# IterableJob which raises Interrupted mid-run. Proves the end-to-end wiring that
# #99 adds: because InterruptHandler is now auto-registered at the head of the
# server chain on boot, the interruption is re-pushed to the queue head and
# exits via JobRetry::Skip — so the job resumes and completes, and nothing lands
# in the retry set.
class InterruptHandlerAutoregisterTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 30.0
  POLL_INTERVAL = 0.1
  SHUTDOWN_TIMEOUT = 15

  def setup
    super
    @ns = "irq-#{::Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @armed_key = "#{@ns}-armed"
    @done_key = "#{@ns}-done"
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    cleanup_keys
    @observer&.close
  ensure
    super
  end

  # The middleware is wired up the moment the gem loads — it does not need a
  # running server. Pin both halves of the auto-registration contract here.
  def test_interrupt_handler_registered_at_head_of_server_chain
    chain = Wurk.configuration.server_middleware

    assert chain.exists?(Wurk::Middleware::InterruptHandler)
    assert_equal Wurk::Middleware::InterruptHandler, chain.entries.first.klass
  end

  def test_sidekiq_job_interrupt_handler_alias_resolves
    assert_same Wurk::Middleware::InterruptHandler, Sidekiq::Job::InterruptHandler
  end

  def test_interrupted_iterable_job_is_repushed_and_resumes_without_retry # rubocop:disable Minitest/MultipleAssertions
    @observer.call('SET', @armed_key, '1')
    push_job
    parent_pid = fork_swarm_supervisor(count: 1)

    begin
      assert wait_for_key(@done_key),
             'job never completed — interrupt should re-push to the queue head and resume'
      assert_equal 0, @observer.call('ZCARD', 'retry').to_i,
                   'interruption must exit via JobRetry::Skip, not schedule a retry'
    ensure
      stop_supervisor(parent_pid)
    end
  end

  private

  def push_job
    config = build_config
    client = Wurk::Client.new(pool: capsule_pool(config), config: config)
    client.push('class' => InterruptRepushIterableWorker.name,
                'args' => [Wurk::Test.redis_url, @armed_key, @done_key],
                'queue' => @queue_name)
  ensure
    config&.reset_redis_pools!
  end

  def build_config
    config = Wurk::Configuration.new
    config.logger = ::Logger.new(IO::NULL)
    config[:timeout] = SHUTDOWN_TIMEOUT
    config
  end

  def capsule_pool(config)
    cap = config.default_capsule
    cap.queues = [@queue_name]
    cap.redis_pool
  end

  def fork_swarm_supervisor(count:)
    ::Process.fork do
      $stdout.reopen(IO::NULL)
      $stderr.reopen(IO::NULL)
      config = build_config
      topology = Wurk::Topology.flat(count: count, queues: [@queue_name], concurrency: 1)
      swarm = Wurk::Swarm.new(topology: topology, config: config, shutdown_timeout: SHUTDOWN_TIMEOUT)
      swarm.boot(install_signals: true)
      swarm.supervise
      exit 0
    end
  end

  def wait_for_key(key) # rubocop:disable Naming/PredicateMethod
    deadline = monotonic_now + POLL_TIMEOUT
    while monotonic_now < deadline
      return true if @observer.call('GET', key)

      sleep POLL_INTERVAL
    end
    false
  end

  # SIGTERM so the supervisor relays a graceful drain to its forked children;
  # otherwise the swarm workers are orphaned and keep BLMOVE-blocking on Redis,
  # hanging the at-exit reap. KILL is the fallback if it overruns the timeout.
  def stop_supervisor(pid)
    return unless pid_alive?(pid)

    ::Process.kill('TERM', pid)
    return if wait_for_pid_exit(pid, timeout: SHUTDOWN_TIMEOUT + 5)

    ::Process.kill('KILL', pid)
    begin
      ::Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def wait_for_pid_exit(pid, timeout:)
    deadline = monotonic_now + timeout
    while monotonic_now < deadline
      return true if ::Process.wait(pid, ::Process::WNOHANG)

      sleep POLL_INTERVAL
    end
    false
  rescue Errno::ECHILD
    true
  end

  def pid_alive?(pid)
    ::Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def cleanup_keys
    return unless @observer

    # Not the shared `retry` key: per-worker DB isolation + FLUSHDB teardown
    # already wipe it, and DEL-ing a global key is a needless cross-test footgun.
    @observer.call('DEL', @armed_key, @done_key, "queue:#{@queue_name}")
    cursor = '0'
    loop do
      cursor, keys = @observer.call('SCAN', cursor, 'MATCH', "queue:#{@queue_name}|*", 'COUNT', 100)
      @observer.call('DEL', *keys) unless keys.empty?
      break if cursor == '0'
    end
  rescue StandardError
    nil
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end
end
