# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'

# The parent's restart counters reach a forked child through the unlinked file
# both share, with no Redis key.
class SwarmRestartCountersTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    log = StringIO.new
    @counters = Wurk::Swarm::RestartCounters.open(logger: ::Logger.new(log))

    raise "RestartCounters.open failed: #{log.string}" unless @counters
  end

  def teardown
    @counters&.close
  ensure
    super
  end

  def test_starts_at_zero
    snap = @counters.read

    assert_equal({ crash: 0, recycle: 0, liveness: 0, rolling: 0 }, snap.restarts)
    assert_equal 0, snap.crash_streak
  end

  def test_counts_by_reason_and_an_unknown_reason_as_a_crash
    @counters.record_restart(:rolling)
    @counters.record_restart(:liveness)
    @counters.record_restart(nil)
    @counters.crash_streak = 3

    snap = @counters.read

    assert_equal({ crash: 1, recycle: 0, liveness: 1, rolling: 1 }, snap.restarts)
    assert_equal 3, snap.crash_streak
  end

  def test_a_forked_child_reads_what_the_parent_writes_after_the_fork
    reader, writer = IO.pipe
    pid = fork do
      writer.close
      reader.gets
      snap = @counters.read
      exit!(snap.restarts[:recycle] == 2 && snap.crash_streak == 1 ? 0 : 1)
    end
    reader.close
    2.times { @counters.record_restart(:recycle) }
    @counters.crash_streak = 1
    writer.puts 'go'
    _, status = Process.wait2(pid)

    assert_predicate status, :success?, 'the child did not see the parent\'s later writes'
  ensure
    writer&.close
    reap(pid)
  end

  # A failed assertion must not leave the child blocked on the pipe: it holds
  # the runner's result pipe open and the run never finishes.
  def reap(pid)
    return unless pid && Process.waitpid(pid, Process::WNOHANG).nil?

    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ECHILD, Errno::ESRCH
    nil
  end

  def test_the_file_is_unlinked_at_once
    Dir.mktmpdir do |dir|
      counters = Wurk::Swarm::RestartCounters.open(dir)

      assert_empty Dir.children(dir)
      counters.record_restart(:crash)

      assert_equal 1, counters.read.restarts[:crash]
    ensure
      counters&.close
    end
  end

  def test_no_temp_dir_logs_and_returns_nil
    log = StringIO.new

    assert_nil Wurk::Swarm::RestartCounters.open('/nonexistent/wurk', logger: ::Logger.new(log))
    assert_match(/restart counters unavailable/, log.string)
  end

  def test_read_after_close_is_nil_and_writes_are_ignored
    @counters.close
    @counters.record_restart(:crash)

    assert_nil @counters.read
  end
end
