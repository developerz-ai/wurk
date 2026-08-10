# frozen_string_literal: true

require_relative '../test_helper'

class PidCacheTest < Wurk::Test::UnitCase
  parallelize_me!

  def test_reports_this_process_pid
    assert_equal ::Process.pid, Wurk::PidCache.pid
  end

  def test_child_sees_its_own_pid_after_fork
    skip 'no fork on this platform' unless ::Process.respond_to?(:fork)

    read, write = IO.pipe
    child = ::Process.fork do
      read.close
      write.write("#{Wurk::PidCache.pid} #{::Process.pid}")
      write.close
      exit!(0)
    end
    write.close
    reported, actual = read.read.split.map(&:to_i)
    read.close
    ::Process.wait(child)

    assert_equal actual, reported
    assert_equal child, reported
  end

  # The whole reason the cache exists is that Component.tid and the fetcher's
  # per-queue key cache use the pid to notice a fork; a stale one would make a
  # child publish the parent's tid and claim into the parent's private list.
  def test_tid_differs_across_a_fork
    skip 'no fork on this platform' unless ::Process.respond_to?(:fork)

    parent_tid = Wurk::Component.tid
    read, write = IO.pipe
    child = ::Process.fork do
      read.close
      write.write(Wurk::Component.tid)
      write.close
      exit!(0)
    end
    write.close
    child_tid = read.read
    read.close
    ::Process.wait(child)

    refute_equal parent_tid, child_tid
  end
end
