# frozen_string_literal: true

require_relative '../test_helper'

# Defined at the top level so Object.const_get resolves inside the forked
# child (constant table is inherited; Minitest lexical scope is not).
class Batch209FastWorker
  include Wurk::Job

  def perform(*); end
end

# Holds its thread until the test sets the release key, marking a running
# sentinel first so the test knows the window is open. Owns its connection —
# never share a socket across forks.
class Batch209GatedWorker
  include Wurk::Job

  def perform(redis_url, running_key, release_key)
    client = RedisClient.config(url: redis_url).new_client
    client.call('SET', running_key, ::Process.pid.to_s, 'EX', 60)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + 20
    until client.call('EXISTS', release_key) == 1
      if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline
        raise "#{release_key} never set — test driver lost?"
      end

      sleep 0.05
    end
  ensure
    client&.close
  end
end

# Real forks, real Redis, real perform. Issue #209 done-when: the parent
# batch's `:complete`/`:success` must NOT fire while a child batch is still
# running, even when the parent's own last job acks first (the pkids gate now
# applies on the parent's own ack path, not just child→parent propagation).
#
# The child batch's only job blocks on a release key, pinning open the exact
# race window: parent's own pending hits 0 in a real worker process while the
# child batch is mid-flight. NEVER mock Redis here.
class BatchNestedCallbacksTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 15.0
  POLL_INTERVAL = 0.05
  # How long the parent's flags must HOLD at "not fired" once the race window
  # is provably open before we believe the gate (vs. just winning a read race).
  GATE_HOLD = 0.5

  def setup
    super
    @ns = "batch209-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @running_key = "#{@ns}-running"
    @release_key = "#{@ns}-release"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:timeout] = 5
    # Require-time registrations only touch the global Wurk.configuration;
    # a fresh Configuration starts with a bare chain, and without the batch
    # middleware the ack path never decrements pending.
    @config.server_middleware.add(Wurk::Batch::ServerMiddleware)
    @observer = RedisClient.config(url: Wurk::Test.redis_url).new_client
  end

  def teardown
    @observer&.call('DEL', @running_key, @release_key,
                    "queue:#{@queue_name}", private_queue_key(@queue_name))
    @observer&.call('SREM', 'queues', @queue_name)
    @observer&.close
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_parent_callbacks_wait_for_running_child_batch_under_real_forks # rubocop:disable Metrics/MethodLength
    parent, child = enqueue_nested_batches
    swarm = Wurk::Swarm.new(topology: topology, config: @config, shutdown_timeout: 5)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      assert wait_until { window_open?(parent, child) },
             'race window never opened: parent job acked + child job running ' \
             "(parent pending=#{batch_field(parent, 'pending').inspect} " \
             "child running=#{@observer.call('EXISTS', @running_key)})"

      hold_deadline = monotonic_now + GATE_HOLD
      while monotonic_now < hold_deadline
        assert_nil batch_field(parent, 'complete'),
                   'parent :complete fired while the child batch was still running (#209)'
        assert_nil batch_field(parent, 'success'),
                   'parent :success fired while the child batch was still running (#209)'
        sleep POLL_INTERVAL
      end

      @observer.call('SET', @release_key, '1', 'EX', 60)

      assert wait_until { batch_field(parent, 'success') == '1' },
             "parent :success never fired after the child finished (within #{POLL_TIMEOUT}s)"
      assert_equal '1', batch_field(parent, 'complete')
      assert_equal '1', batch_field(child, 'success')

      child_at  = batch_field(child, 'success_at').to_f
      parent_at = batch_field(parent, 'success_at').to_f

      assert_operator child_at, :<=, parent_at,
                      'child :success must precede parent :success (spec §2.4)'
    ensure
      @observer.call('SET', @release_key, '1', 'EX', 60) # never strand the gated worker
      begin
        swarm.shutdown(timeout: 5)
      rescue StandardError
        nil
      end
      stop_supervisor_thread(supervisor, 10)
    end
  end

  private

  def topology
    # Concurrency 2: the gated job must not starve the parent's fast job.
    Wurk::Topology.flat(count: 1, queues: [@queue_name], concurrency: 2)
  end

  # Parent batch: one fast own job + a nested child batch whose only job
  # blocks until @release_key appears. Pushed through Wurk::Client so the
  # batch client middleware stamps bids (same contract production uses).
  def enqueue_nested_batches
    parent = Wurk::Batch.new
    child = nil
    parent.jobs do
      Wurk::Client.push('class' => Batch209FastWorker.name, 'args' => [],
                        'queue' => @queue_name, 'retry' => false)
      child = Wurk::Batch.new
      child.jobs do
        Wurk::Client.push('class' => Batch209GatedWorker.name,
                          'args' => [Wurk::Test.redis_url, @running_key, @release_key],
                          'queue' => @queue_name, 'retry' => false)
      end
    end
    [parent, child]
  end

  # The #209 race window: the parent's own job has fully acked (pending 0)
  # while the child batch's job is provably still inside perform.
  def window_open?(parent, child)
    batch_field(parent, 'pending').to_i.zero? &&
      batch_field(child, 'pending').to_i == 1 &&
      @observer.call('EXISTS', @running_key) == 1
  end

  def batch_field(batch, field)
    @observer.call('HGET', "b-#{batch.bid}", field)
  end

  def wait_until # rubocop:disable Naming/PredicateMethod
    deadline = monotonic_now + POLL_TIMEOUT
    until monotonic_now > deadline
      return true if yield

      sleep POLL_INTERVAL
    end
    false
  end

  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  def private_queue_key(queue_name)
    Wurk::Fetcher::Reliable.private_queue_name("queue:#{queue_name}")
  end
end
