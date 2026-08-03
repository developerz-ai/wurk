# frozen_string_literal: true

require_relative '../test_helper'
require 'json'

# Fork safety of the reliable_push outage buffer (#101 audit S1). The buffer,
# its drainer and both of its mutexes are process-global, so a fork hands the
# child a copy of all three: payloads the parent will replay itself, a Drainer
# whose thread didn't survive, and mutexes that may be locked by a thread that
# no longer exists. Drives `Buffered.reset_after_fork!` directly, in-process —
# `test/integration/client_buffer_fork_test.rb` covers the same ground through
# real forks.
#
# Mutates the same global Client/Buffered singletons as ClientBufferedTest, so
# it follows the same contract: opt into the parallel runner, serialize within
# the class.
class ClientBufferedForkTest < Wurk::Test::UnitCase
  parallelize_me!

  MUTEX = Mutex.new

  # Never a real pid, so `reset_after_fork!` sees "another process owns this
  # state" — what a child observes after fork.
  FOREIGN_PID = -1

  def run(*args, &)
    MUTEX.synchronize { super }
  end

  def setup
    super
    @pool = Wurk.configuration.redis_pool
    @class_name = "BufferedForkJob@#{Process.pid}-#{object_id}"
    @queue      = "bfq-#{Process.pid}-#{object_id}"
    Wurk::Client.reliable_push!
    Wurk::Client::Buffered.reset!
  end

  def teardown
    Wurk::Client.reliable_push_drainer_stop!
    Wurk::Client::Buffered.reset!
    Wurk::Client::Buffered.instance_variable_set(:@owner_pid, Process.pid)
    @pool.with do |conn|
      conn.call('DEL', "queue:#{@queue}")
      conn.call('SREM', 'queues', @queue)
    end
  ensure
    super
  end

  # --- pid guard ---------------------------------------------------------

  def test_reset_is_a_no_op_in_the_owning_process
    buffer_payloads(2)

    refute Wurk::Client::Buffered.reset_after_fork!, 'reset must not fire outside a fork'
    assert_equal 2, Wurk::Client::Buffered.buffer_size
  end

  def test_reset_runs_once_per_forked_process
    simulate_fork!

    assert Wurk::Client::Buffered.reset_after_fork!
    refute Wurk::Client::Buffered.reset_after_fork!, 'the second call site must be a no-op'
  end

  # --- inherited buffer --------------------------------------------------

  # The parent keeps the same payloads and replays them on its own next push;
  # a child that replayed too would enqueue each buffered job once per fork.
  def test_reset_drops_the_inherited_buffer
    buffer_payloads(3)
    simulate_fork!
    Wurk::Client::Buffered.reset_after_fork!

    assert_equal 0, Wurk::Client::Buffered.buffer_size
  end

  # The captured factory closes over the parent's pre-fork pool — the child
  # must build a client against its own.
  def test_reset_drops_the_captured_client_factory
    buffer_payloads(1)

    refute_nil Wurk::Client::Buffered.buffer_client_factory

    simulate_fork!
    Wurk::Client::Buffered.reset_after_fork!

    assert_nil Wurk::Client::Buffered.buffer_client_factory
  end

  # --- inherited mutexes -------------------------------------------------

  def test_reset_replaces_both_mutexes
    before = mutexes
    simulate_fork!
    Wurk::Client::Buffered.reset_after_fork!

    refute_same before[0], mutexes[0]
    refute_same before[1], mutexes[1]
  end

  # The deadlock the fork hook exists for: a fork taken while another thread
  # held the buffer mutex leaves the child holding a locked mutex with no owner
  # to release it, and `Client#push` drains (→ synchronize) before pushing.
  def test_reset_clears_a_buffer_mutex_locked_by_a_vanished_owner
    holder = lock_buffer_mutex
    simulate_fork!
    Wurk::Client::Buffered.reset_after_fork!

    assert_equal(0, with_deadline { Wurk::Client::Buffered.buffer_size })
  ensure
    release(holder)
  end

  def test_reset_clears_an_install_mutex_locked_by_a_vanished_owner
    holder = lock_install_mutex
    simulate_fork!
    Wurk::Client::Buffered.reset_after_fork!

    refute(with_deadline { Wurk::Client.reliable_push_drainer_running? })
  ensure
    release(holder)
  end

  # --- inherited drainer -------------------------------------------------

  def test_reset_leaves_the_drainer_unset_when_the_parent_had_none
    simulate_fork!
    Wurk::Client::Buffered.reset_after_fork!

    refute_predicate Wurk::Client, :reliable_push_drainer_running?
  end

  def test_reset_re_arms_an_equivalent_drainer
    Wurk::Client::Buffered.start_drainer!(interval: 0.05, client_factory: idle_factory)
    inherited = drainer
    kill_drainer_thread(inherited)
    simulate_fork!
    Wurk::Client::Buffered.reset_after_fork!

    refute_same inherited, drainer
    assert_in_delta 0.05, drainer.interval
    assert_predicate Wurk::Client, :reliable_push_drainer_running?
  end

  # End-to-end: the re-armed drainer must flush the buffer the *child* fills,
  # through the child's own pool — not the failing one the parent pinned.
  def test_re_armed_drainer_drains_the_childs_own_buffer
    Wurk::Client::Buffered.start_drainer!(interval: 0.02, client_factory: idle_factory)
    kill_drainer_thread(drainer)
    buffer_payloads(1)
    simulate_fork!
    Wurk::Client::Buffered.reset_after_fork!

    buffer_payloads(1, args: ['post-fork'])

    assert(eventually? { queued_args == [['post-fork']] },
           'the re-armed drainer never flushed the buffer through the default pool')
  end

  private

  def simulate_fork!
    Wurk::Client::Buffered.instance_variable_set(:@owner_pid, FOREIGN_PID)
  end

  def drainer
    Wurk::Client::Buffered.instance_variable_get(:@drainer)
  end

  # Satisfies the drainer's factory contract without touching Redis: drain!
  # pops nothing from an empty buffer, so no method on the client is called.
  def idle_factory
    -> { Object.new }
  end

  def mutexes
    %i[@install_mutex @buffer_mutex].map { |ivar| Wurk::Client::Buffered.instance_variable_get(ivar) }
  end

  # A fork's child never gets the parent's drainer thread; killing it leaves
  # exactly the object graph the child inherits.
  def kill_drainer_thread(target)
    thread = target.instance_variable_get(:@thread)
    thread.kill
    thread.join(5.0)
  end

  # Payloads reach the buffer the production way — a push against a dead pool —
  # so the pinned client factory is captured just like it is in a real outage.
  def buffer_payloads(count, args: [])
    client = Wurk::Client.new(pool: failing_pool)
    count.times { client.push({ 'class' => @class_name, 'args' => args, 'queue' => @queue }) }
  end

  def lock_buffer_mutex
    park_holding(Wurk::Client::Buffered.send(:buffer_mutex))
  end

  def lock_install_mutex
    park_holding(Wurk::Client::Buffered.send(:install_mutex))
  end

  # Holds `mutex` in a parked thread until killed. Stands in for the owner that
  # a fork leaves behind: locked, with nobody left to unlock it.
  def park_holding(mutex)
    holder = Thread.new { mutex.synchronize { Thread.stop } }
    flunk('holder thread never took the mutex') unless eventually? { mutex.locked? }

    holder
  end

  def release(holder)
    holder&.kill
    holder&.join(5.0)
  end

  # Runs the block on its own thread so a mutex the reset failed to replace
  # fails the test instead of hanging the whole suite.
  def with_deadline(seconds = 5.0, &)
    thread = Thread.new(&)
    unless thread.join(seconds)
      thread.kill

      flunk('blocked past deadline — an inherited mutex was not replaced')
    end
    thread.value
  end

  def eventually?(seconds = 3.0)
    deadline = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) + seconds
    until yield
      return false if ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    true
  end

  def queued_args
    @pool.with { |c| c.call('LRANGE', "queue:#{@queue}", 0, -1) }.map { |s| JSON.parse(s)['args'] }
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
