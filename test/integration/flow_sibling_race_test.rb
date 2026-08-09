# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'timeout'

# Real forks, real Redis, for the correctness core of slice 11 (docs/plans/
# 2026/08/07/101-beyond-sidekiq/11-flows.md step 3): "siblings finishing
# simultaneously across real forks fire the parent exactly once."
#
# FlowCompletionTest already proves the sibling race in-process with real
# threads (`test_siblings_finishing_at_once_release_their_parent_exactly_once`)
# — that catches a race between callers sharing one Ruby process's connection
# pool, but says nothing about independent Redis connections opened by
# independent processes, which is what N swarm children each finishing one
# fan-in dependency actually looks like. Only a real fork can tell the two
# apart — same reasoning as DebounceConcurrentTest for #101 09-debounce.
#
# NEVER mock Redis here. Synchronization between parent and children is a
# Redis key, not a Ruby Mutex/Queue — those don't cross a fork boundary.
class FlowSiblingRaceTest < Wurk::Test::UnitCase
  parallelize_me!

  # Deep enough that a lost race (the parent released twice, or never) shows
  # up reliably rather than by luck of the scheduler.
  SIBLINGS = 8
  CHILD_TIMEOUT = 15
  CLEAN = 0
  CHILD_FAILED = 1

  class RootJob
    include Wurk::Job

    def perform(*); end
  end

  class MergeJob
    include Wurk::Job

    def perform(*); end
  end

  def setup
    super
    @ns          = "flowrace-#{Process.pid}-#{object_id}"
    @queue       = "#{@ns}-q"
    @callback    = "#{@ns}-cb"
    @barrier_key = "#{@ns}:barrier"
    @ready_key   = "#{@ns}:ready"
    @pool        = Wurk.configuration.redis_pool
    @pool.with { |conn| Wurk::Lua::Loader.script_load_all(conn) }
  end

  def teardown
    @pool.with do |conn|
      conn.call('DEL', @barrier_key, @ready_key, "queue:#{@queue}", "queue:#{@callback}")
    end
  ensure
    super
  end

  def test_siblings_finishing_simultaneously_across_real_forks_fire_the_parent_exactly_once
    flow = fan_in(SIBLINGS).run
    pids = (0...SIBLINGS).map { |index| fork_child(flow.fid, index) }

    wait_for_children_ready(SIBLINGS)
    # Every child is already parked on the barrier poll below; flipping it
    # once is the closest independent processes get to "simultaneous".
    @pool.with { |conn| conn.call('SET', @barrier_key, '1') }

    statuses = pids.map { |pid| wait_status(pid) }

    assert_equal(Array.new(SIBLINGS, CLEAN), statuses,
                 "child exit codes — #{CHILD_FAILED}: raised, or the release never landed")
    merge_index = SIBLINGS

    assert_equal(1, queued.count { |job| job['jid'] == flow.jids[merge_index] },
                 'the fan-in node must be released by exactly one of its 8 racing dependencies')
    assert_equal 'enqueued', node_record(flow, merge_index)['state']
    assert_equal '0', node_record(flow, merge_index)['remaining']
    assert_equal %w[running 1], flow_record(flow).values_at('state', 'pending')
  end

  private

  # N roots, all feeding one merge node — the smallest graph shape where N
  # independent processes can each be "the one that releases the parent".
  def fan_in(count)
    flow = Wurk::Flow.new do |f|
      roots = Array.new(count) { |i| f.job(RootJob, i, queue: @queue) }
      f.job(MergeJob, depends_on: roots, queue: @queue)
    end
    flow.callback_queue = @callback
    flow
  end

  # `exit!` skips at_exit (SimpleCov) like the other fork tests in this suite.
  def fork_child(fid, index)
    ::Process.fork do
      code = begin
        Timeout.timeout(CHILD_TIMEOUT) { child_body(fid, index) }
        CLEAN
      rescue StandardError
        CHILD_FAILED
      end
      ::Process.exit!(code)
    end
  end

  # Step 5 of the boot ordering: reconnect inside the child rather than share
  # the parent's inherited (and now cross-process-shared) socket.
  def child_body(fid, index)
    Wurk.configuration.reset_redis_pools!
    Wurk.redis { |c| c.call('INCR', @ready_key) }
    wait_for_barrier
    Wurk::Flow::Completion.new.on_success(nil, { 'fid' => fid, 'node' => index })
  end

  def wait_for_barrier
    raise 'barrier never released' unless eventually? { Wurk.redis { |c| c.call('GET', @barrier_key) } == '1' }
  end

  def wait_for_children_ready(count)
    ready = eventually? { @pool.with { |conn| conn.call('GET', @ready_key) }.to_i >= count }
    return if ready

    flunk("only #{@pool.with { |conn| conn.call('GET', @ready_key) }} of #{count} children became ready")
  end

  def eventually?(seconds = CHILD_TIMEOUT)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + seconds
    until yield
      return false if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
    true
  end

  def wait_status(pid)
    _, status = ::Process.wait2(pid)
    status.exitstatus
  end

  def queued
    @pool.with { |conn| conn.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |raw| JSON.parse(raw) }
  end

  def flow_record(flow) = hgetall(Wurk::Keys.flow(flow.fid))
  def node_record(flow, index) = hgetall(Wurk::Keys.flow_node(flow.fid, index))

  def hgetall(key)
    raw = @pool.with { |conn| conn.call('HGETALL', key) }
    raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
  end
end

# A 3-level DAG (two roots -> a merge that depends on both -> a final node
# that depends on the merge) run to completion under a real swarm: real
# forks, real fetch, real perform, real acks — the shape the sibling-race
# test above deliberately does not exercise (it drives Completion directly to
# isolate the race). Split into its own class so a hang in one boot doesn't
# also block the barrier-based race test above under parallel_fork.
class FlowThreeLevelSwarmTest < Wurk::Test::UnitCase
  parallelize_me!

  POLL_TIMEOUT = 15.0
  POLL_INTERVAL = 0.05

  class Level0Job
    include Wurk::Job

    def perform(*); end
  end

  class Level1Job
    include Wurk::Job

    def perform(*); end
  end

  class Level2Job
    include Wurk::Job

    def perform(*); end
  end

  def setup
    super
    @ns = "flow3-#{Process.pid}-#{object_id}"
    @queue_name = "#{@ns}-q"
    @config = Wurk::Configuration.new
    @config.logger = ::Logger.new(IO::NULL)
    @config[:timeout] = 5
    # A fresh Configuration starts with a bare chain (require-time
    # registrations only touch the global Wurk.configuration) — without these
    # two, a real child's ack never advances the flow at all.
    @config.server_middleware.add(Wurk::Batch::ServerMiddleware)
    @config.death_handlers << Wurk::Batch::DeathHandler
    @observer = Wurk.configuration.redis_pool
  end

  def teardown
    @observer.with { |conn| conn.call('DEL', "queue:#{@queue_name}", private_queue_key(@queue_name)) }
    @observer.with { |conn| conn.call('SREM', 'queues', @queue_name) }
    @config&.reset_redis_pools!
  ensure
    super
  end

  def test_a_three_level_flow_completes_under_a_real_swarm
    flow = three_level_flow.run
    swarm = Wurk::Swarm.new(topology: topology, config: @config, shutdown_timeout: 5)
    supervisor = nil

    begin
      swarm.boot(install_signals: false)
      supervisor = Thread.new { swarm.supervise }

      assert wait_until { flow_record(flow)['state'] == 'succeeded' },
             "flow never reached succeeded (state=#{flow_record(flow)['state'].inspect}, " \
             "pending=#{flow_record(flow)['pending'].inspect})"

      assert_equal(%w[succeeded succeeded succeeded succeeded],
                   (0..3).map { |i| node_record(flow, i)['state'] })
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

  def topology
    Wurk::Topology.flat(count: 2, queues: [@queue_name], concurrency: 2)
  end

  # a, b (level 0) -> merge (level 1, depends on both) -> final (level 2).
  def three_level_flow
    flow = Wurk::Flow.new do |f|
      a = f.job(Level0Job, name: :a, queue: @queue_name)
      b = f.job(Level0Job, name: :b, queue: @queue_name)
      merge = f.job(Level1Job, name: :merge, depends_on: [a, b], queue: @queue_name)
      f.job(Level2Job, name: :final, depends_on: merge, queue: @queue_name)
    end
    flow.callback_queue = @queue_name
    flow
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

  def flow_record(flow) = hgetall(Wurk::Keys.flow(flow.fid))
  def node_record(flow, index) = hgetall(Wurk::Keys.flow_node(flow.fid, index))

  def hgetall(key)
    raw = @observer.with { |conn| conn.call('HGETALL', key) }
    raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
  end
end
