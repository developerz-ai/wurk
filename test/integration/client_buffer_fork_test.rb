# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'timeout'

# Real forks, real Redis, for the reliable_push outage buffer (#101 audit S1).
# A forked child used to inherit the parent's buffered payloads — replaying
# every one of them once per child — plus a Drainer whose thread didn't survive
# the fork and which nothing restarted, so a child that buffered during a later
# outage sat on those payloads for the rest of its life. Nothing here calls
# `reset_after_fork!` explicitly: the `Process._fork` hook is what has to fire.
#
# Mutates the same global Client/Buffered singletons as ClientBufferedTest, so
# it follows the same contract: opt into the parallel runner, serialize within
# the class.
class ClientBufferForkTest < Wurk::Test::UnitCase
  parallelize_me!

  MUTEX = Mutex.new

  # Generous: the assertion is "not blocked forever", and the child does real
  # Redis work. A regression trips it in bounded time instead of hanging CI.
  CHILD_TIMEOUT = 15

  # A forked child reports through its exit status — one code per leg, so a CI
  # failure names which half of the reset regressed instead of just "1".
  CLEAN        = 0
  CHILD_FAILED = 1
  DIRTY_BUFFER = 2
  DEAD_DRAINER = 3

  BUFFERED = %w[buffered-0 buffered-1 buffered-2].freeze
  CHILDREN = %w[child-0 child-1].freeze

  def run(*args, &)
    MUTEX.synchronize { super }
  end

  def setup
    super
    @pool = Wurk.configuration.redis_pool
    @class_name = "BufferForkJob@#{Process.pid}-#{object_id}"
    @queue      = "bkq-#{Process.pid}-#{object_id}"
    Wurk::Client.reliable_push!
    Wurk::Client::Buffered.reset!
  end

  def teardown
    Wurk::Client.reliable_push_drainer_stop!
    Wurk::Client::Buffered.reset!
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
    end
  ensure
    super
  end

  def test_forked_children_start_clean_and_push_without_blocking
    buffer_during_outage

    assert_equal BUFFERED.size, Wurk::Client::Buffered.buffer_size

    start_parent_drainer
    pids = holding_buffer_mutex { CHILDREN.map { |tag| fork_child(tag) } }

    assert_equal [CLEAN, CLEAN], pids.map { |pid| wait_status(pid) },
                 "child exit codes — #{DIRTY_BUFFER}: inherited the parent's buffer, " \
                 "#{DEAD_DRAINER}: drainer not re-armed, " \
                 "#{CHILD_FAILED}: raised or blocked past #{CHILD_TIMEOUT}s"
  end

  # The whole point of dropping the child's copy: the parent still owns those
  # payloads and replays them itself, so every buffered job is enqueued exactly
  # once no matter how many children were forked over it.
  def test_only_the_parent_replays_its_buffer
    buffer_during_outage
    start_parent_drainer
    pids = holding_buffer_mutex { CHILDREN.map { |tag| fork_child(tag) } }
    pids.each { |pid| wait_status(pid) }
    # Stopped before the replay: a drain tick that has already popped the head
    # would otherwise hold that payload while the push below drains.
    Wurk::Client.reliable_push_drainer_stop!

    push('parent-drain') # drains the parent's buffer on the way through

    assert_equal (BUFFERED + CHILDREN + ['parent-drain']).sort, queued_args.sort
  end

  private

  def buffer_during_outage
    failing = Wurk::Client.new(pool: failing_pool)
    BUFFERED.each { |tag| failing.push(item(tag)) }
  end

  # A real second thread, mid-drain-loop, at the moment of the fork — the
  # production shape of the bug. It inherits the failing pool captured while
  # buffering, so the parent's own buffer can never drain out from under the
  # assertions; only the explicit push through the default pool replays it.
  def start_parent_drainer
    Wurk::Client::Buffered.start_drainer!(interval: 0.05)
  end

  def push(tag)
    Wurk::Client.new.push(item(tag))
  end

  def item(tag)
    { 'class' => @class_name, 'args' => [tag], 'queue' => @queue }
  end

  # Forks at the worst moment: the buffer mutex held by a thread the child
  # won't have. That also parks the drainer mid-loop, so the buffer the child
  # inherits is exactly the one asserted on above. Released afterwards so the
  # parent can go on using its own buffer.
  def holding_buffer_mutex
    mutex = Wurk::Client::Buffered.send(:buffer_mutex)
    holder = Thread.new { mutex.synchronize { Thread.stop } }
    flunk('holder thread never took the buffer mutex') unless eventually? { mutex.locked? }

    yield
  ensure
    holder&.kill
    holder&.join(5.0)
  end

  # `exit!` skips at_exit (SimpleCov) like the other fork tests. Timeout is the
  # net for the hang case: reading `buffer_size` takes the buffer mutex, so a
  # child that inherited a stuck one fails in bounded time instead of parking
  # this test's `wait2` forever.
  def fork_child(tag)
    ::Process.fork do
      code = begin
        Timeout.timeout(CHILD_TIMEOUT) { child_body(tag) }
      rescue StandardError
        CHILD_FAILED
      end
      ::Process.exit!(code)
    end
  end

  # Step 5 of the boot ordering, minus the swarm: the child opens its own pool
  # before touching Redis. The push runs whatever the verdict, so the sibling
  # test can still account for every job this child enqueued.
  def child_body(tag)
    Wurk.configuration.reset_redis_pools!
    code = child_state
    push(tag)
    code
  end

  # The drainer leg is the second half of the fix: a child that kept the
  # parent's Drainer object holds a thread that died in the fork, so nothing
  # would ever flush what this process buffers.
  def child_state
    return DIRTY_BUFFER unless Wurk::Client::Buffered.buffer_size.zero?
    return DEAD_DRAINER unless Wurk::Client.reliable_push_drainer_running?

    CLEAN
  end

  def wait_status(pid)
    _, status = ::Process.wait2(pid)
    status.exitstatus
  end

  def eventually?(seconds = 5.0)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + seconds
    until yield
      return false if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

      sleep 0.005
    end
    true
  end

  def queued_args
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.flat_map { |s| JSON.parse(s)['args'] }
  end

  def failing_pool
    pool = Object.new
    pool.define_singleton_method(:with) { |&blk| blk.call(FailingConn.new) }
    pool
  end

  class FailingConn
    def pipelined
      yield self
    end

    def call(*)
      raise RedisClient::ConnectionError, 'simulated outage'
    end
  end
end
