# frozen_string_literal: true

require_relative '../test_helper'
require 'json'
require 'timeout'

# Real forks, real Redis, for Wurk::Debounce (#101 09-debounce-throttle §
# "Concurrency: two processes debouncing the same key simultaneously → one
# job"). DebounceTest already proves this in-process with threads on shared
# connections (`test_concurrent_producers_leave_one_entry`); that catches a
# race between two callers of the *same* Ruby process's pool but says nothing
# about two independent Redis connections opened by two independent
# processes — which is the actual deployment shape multiple Wurk swarm
# children enqueuing the same debounce key represents. Only a real fork can
# tell the two apart.
#
# NEVER mock Redis here. Synchronization between parent and children is a
# Redis key, not a Ruby Mutex/Queue — those don't cross a fork boundary.
class DebounceConcurrentTest < Wurk::Test::UnitCase
  parallelize_me!

  # Generous: the assertion is "not blocked forever", and each child does real
  # Redis work. A regression trips it in bounded time instead of hanging CI.
  CHILD_TIMEOUT = 15
  # Long enough that nothing under test is promoted mid-assertion by a
  # scheduler running in another suite.
  WAIT = 30
  MAX_WAIT = 60
  # Per child. Deep enough to make a lost race (two entries surviving instead
  # of one) exercise many script invocations racing the same key, not just
  # the first one.
  PUSHES_PER_CHILD = 100

  CLEAN        = 0
  CHILD_FAILED = 1

  def setup
    super
    @class_name  = "DebounceForkJob@#{Process.pid}-#{object_id}"
    @queue       = "dbfork-#{Process.pid}-#{object_id}"
    @barrier_key = "dbfork:barrier:#{Process.pid}-#{object_id}"
    @ready_key   = "dbfork:ready:#{Process.pid}-#{object_id}"
    @pool        = Wurk.configuration.redis_pool
    @pool.with { |conn| Wurk::Lua::Loader.script_load_all(conn) }
  end

  def test_two_processes_debouncing_the_same_key_concurrently_leave_one_entry
    pids = %w[a b].map { |tag| fork_child(tag) }
    wait_for_children_ready(pids.size)
    # Both children are already parked on the barrier GET-poll below; flipping
    # it once is the closest two independent processes get to "simultaneous".
    @pool.with { |conn| conn.call('SET', @barrier_key, '1') }

    statuses = pids.map { |pid| wait_status(pid) }

    assert_equal [CLEAN, CLEAN], statuses,
                 "child exit codes — #{CHILD_FAILED}: raised or blocked past #{CHILD_TIMEOUT}s"
    assert_equal 1, scheduled_entries.size,
                 'two processes racing the same debounce key must leave exactly one entry in `schedule`'
    winner = scheduled_entries.first
    all_jids = %w[a b].flat_map { |tag| Array.new(PUSHES_PER_CHILD) { |i| jid(tag, i) } }

    assert_includes all_jids, winner['jid'], 'the surviving entry must be one of the raced pushes, not a merge'
  end

  private

  def jid(tag, idx) = "#{tag}-#{idx}"

  def job(tag, idx)
    { 'class' => @class_name, 'args' => [1], 'queue' => @queue, 'jid' => jid(tag, idx),
      'created_at' => 1_700_000_000.0 }
  end

  # `exit!` skips at_exit (SimpleCov) like the other fork tests.
  def fork_child(tag)
    ::Process.fork do
      code = begin
        Timeout.timeout(CHILD_TIMEOUT) { child_body(tag) }
        CLEAN
      rescue StandardError
        CHILD_FAILED
      end
      ::Process.exit!(code)
    end
  end

  # Step 5 of the boot ordering: the child opens its own pool before touching
  # Redis, never the parent's inherited (and now cross-process-shared) socket.
  def child_body(tag)
    Wurk.configuration.reset_redis_pools!
    Wurk.redis { |c| c.call('INCR', @ready_key) }
    wait_for_barrier
    PUSHES_PER_CHILD.times { |i| Wurk::Debounce.schedule(job(tag, i), wait: WAIT, max_wait: MAX_WAIT) }
  end

  def wait_for_barrier
    raise 'barrier never released' unless eventually? { Wurk.redis { |c| c.call('GET', @barrier_key) } == '1' }
  end

  def wait_for_children_ready(count)
    ready = eventually? { @pool.with { |conn| conn.call('GET', @ready_key) }.to_i >= count }
    flunk("only #{@pool.with { |conn| conn.call('GET', @ready_key) }} of #{count} children became ready") unless ready
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

  # ZRANGE the shared zset and keep only this test's members. Sibling suites
  # write non-JSON probe members there; skip those rather than blow up.
  def scheduled_entries
    @pool.with { |conn| conn.call('ZRANGE', 'schedule', 0, -1) }.filter_map do |member|
      parsed = JSON.parse(member)
      parsed if parsed['class'] == @class_name
    rescue JSON::ParserError
      next
    end
  end
end
