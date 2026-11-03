# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'
require 'rbconfig'
require 'socket'
require 'tmpdir'

# Two suite runs on one logical DB FLUSHDB each other, which reads as random
# integration failures. Locks, not Redis: nothing here connects to a server.
class RedisDbLockTest < Wurk::Test::UnitCase
  LOCK = Wurk::Test::RedisDbLock
  URL = 'redis://example.test:6379/0'

  def setup
    super
    @saved_owner = ENV.delete(LOCK::OWNER_ENV)
    # The running suite's own locks: dropping the reference would let GC release them.
    @saved_files = LOCK.instance_variable_get(:@files)
    @dir = Dir.mktmpdir('wurk-db-lock')
  end

  def teardown
    LOCK.instance_variable_get(:@files)&.each(&:close) unless LOCK.instance_variable_get(:@files).equal?(@saved_files)
    LOCK.instance_variable_set(:@files, @saved_files)
    ENV[LOCK::OWNER_ENV] = @saved_owner
    FileUtils.remove_entry(@dir)
  ensure
    super
  end

  # A separate process, because an flock is per open file and the suite's own
  # process must be the one that gets refused.
  def holding(databases)
    script = <<~RUBY
      require #{File.expand_path('../support/redis_db_lock', __dir__).inspect}
      Wurk::Test::RedisDbLock.acquire!(#{databases.inspect}, url: #{URL.inspect}, dir: #{@dir.inspect})
      puts 'held'
      STDOUT.flush
      STDIN.read
    RUBY
    env = { LOCK::OWNER_ENV => nil }
    Open3.popen2(env, RbConfig.ruby, '-e', script) do |stdin, stdout, _wait|
      assert_equal "held\n", stdout.gets
      yield
    ensure
      stdin.close
    end
  end

  def test_an_overlapping_run_is_refused_and_told_what_to_do
    holding([5, 6]) do
      error = assert_raises(LOCK::Held) { LOCK.acquire!([6, 7], url: URL, dir: @dir) }

      assert_includes error.message, 'DB 6'
      assert_includes error.message, 'pid '
      assert_includes error.message, 'WURK_TEST_DB_OFFSET'
      refute_includes error.message, 'DB 7:', 'only the DB actually held is named'
    end
  end

  def test_runs_on_separate_dbs_do_not_collide
    holding([5, 6]) { assert_equal 2, LOCK.acquire!([7, 8], url: URL, dir: @dir).size }
  end

  def test_the_same_db_on_another_server_is_not_a_collision
    holding([5]) { assert_equal 1, LOCK.acquire!([5], url: 'redis://other.test:6379/0', dir: @dir).size }
  end

  def test_a_finished_run_leaves_nothing_behind
    holding([5]) { nil }

    assert_equal 1, LOCK.acquire!([5], url: URL, dir: @dir).size
  end

  # A swarm child leaked by a crashed run used to keep the flock and name a dead pid.
  def test_a_leaked_child_does_not_keep_the_lock
    script = <<~RUBY
      require #{File.expand_path('../support/redis_db_lock', __dir__).inspect}
      Wurk::Test::RedisDbLock.acquire!([5], url: #{URL.inspect}, dir: #{@dir.inspect})
      child = Process.fork { STDOUT.reopen(File::NULL); sleep 60 }
      puts child
    RUBY
    out, status = Open3.capture2({ LOCK::OWNER_ENV => nil }, RbConfig.ruby, '-e', script)
    leaked = Integer(out)

    assert_predicate status, :success?
    assert_equal 1, LOCK.acquire!([5], url: URL, dir: @dir).size
  ensure
    ::Process.kill('KILL', leaked) if leaked
  end

  def test_a_suite_spawned_from_a_suite_shares_its_dbs
    holding([5]) do
      ENV[LOCK::OWNER_ENV] = '1'

      assert_empty LOCK.acquire!([5], url: URL, dir: @dir)
    end
  end

  def test_the_dedicated_db_lock_runs_its_block_and_releases
    ran = LOCK.with_dedicated(15, url: URL, dir: @dir) { :ran }

    assert_equal :ran, ran
    assert_equal 1, LOCK.acquire!([15], url: URL, dir: @dir).size
  end

  def test_the_neighbour_note_stays_silent_on_a_server_of_its_own
    assert_nil Wurk::Test::RedisNeighbours.note(0, 0)
    assert_includes Wurk::Test::RedisNeighbours.note(0, 3), '3 other connection'
    assert_includes Wurk::Test::RedisNeighbours.note(4, 1), '4 other connection'
  end

  def test_the_neighbour_count_is_zero_when_it_cannot_tell
    assert_equal 0, Wurk::Test::RedisNeighbours.count('redis://127.0.0.1:1/5')
  end

  # What a contributor with no Redis used to get: a connection backtrace, then
  # `marshal data too short` from inside the fork.
  def test_a_missing_server_stops_the_suite_with_directions
    listener = TCPServer.new('127.0.0.1', 0)
    port = listener.addr[1]
    listener.close
    helper = File.expand_path('../test_helper', __dir__)
    env = { 'REDIS_URL' => "redis://127.0.0.1:#{port}/0", 'COVERAGE' => nil, 'RUBYOPT' => '-rbundler/setup',
            LOCK::OWNER_ENV => nil }
    out, status = Open3.capture2e(env, RbConfig.ruby, '-e', "require #{helper.inspect}; exit!(0)")

    assert_equal 75, status.exitstatus, out
    assert_includes out, "no Redis at 127.0.0.1:#{port}"
    assert_includes out, 'docker run'
    refute_includes out, 'marshal data'
  end
end
