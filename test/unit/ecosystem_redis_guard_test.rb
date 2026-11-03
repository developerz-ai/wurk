# frozen_string_literal: true

require_relative '../test_helper'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../ecosystem/redis_guard'

# bin/test-ecosystem runs third-party suites that flush the DB they connect to around
# every example, so each way of landing on DB 0 is driven through the real script.
# Stub `git`, `bundle`, `redis-server` and `redis-cli` on PATH: `bundle` running at all
# is the proof a suite would have started.
class EcosystemRedisGuardTest < Wurk::Test::UnitCase
  SCRIPT = File.expand_path('../../bin/test-ecosystem', __dir__)
  GOOD_URL = 'redis://127.0.0.1:6390/15'
  UNSAFE_URLS = {
    'db zero' => 'redis://10.0.0.1:6380/0',
    'query after db zero' => 'redis://10.0.0.1:6380/0?x=1',
    'no db' => 'redis://10.0.0.1:6380',
    'unix socket' => 'unix:///tmp/redis.sock',
    'unix socket with db' => 'unix:///tmp/redis.sock?db=15',
    'query overriding the path' => 'redis://10.0.0.1:6380/15?db=0',
    'another db' => 'redis://10.0.0.1:6380/3',
    'the local default server' => 'redis://localhost:6379/15',
    'the local default by implication' => 'redis://127.0.0.1/15',
    'not a url' => 'host:6380'
  }.freeze

  def setup
    super
    @dir = Dir.mktmpdir
    @bin = File.join(@dir, 'bin')
    @log = File.join(@dir, 'bundle.log')
    FileUtils.mkdir_p(@bin)
    stub('git', %(if [ "$1" = clone ]; then mkdir -p "$4/.git"; fi; exit 0))
    stub('bundle', %(echo "$* REDIS_URL=$REDIS_URL" >> "#{@log}"; exit 0))
    stub('redis-server', %(exec sleep 30))
    stub('redis-cli', 'echo PONG')
    harness('some-gem')
  end

  def teardown
    FileUtils.remove_entry(@dir)
    super
  end

  def stub(name, body)
    path = File.join(@bin, name)
    File.write(path, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod(0o755, path)
  end

  def harness(name, prepare: nil)
    @harness = File.join(@dir, 'harnesses', name)
    FileUtils.mkdir_p(@harness)
    File.write(File.join(@harness, 'PIN'), "repo: https://example.invalid/x\nsha: abc\n")
    return unless prepare

    File.write(File.join(@harness, 'prepare'), "#!/usr/bin/env bash\n#{prepare}\n")
    File.chmod(0o755, File.join(@harness, 'prepare'))
  end

  def run_script(url: GOOD_URL, env: {})
    full_env = { 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'ECOSYSTEM_HARNESS_DIR' => File.join(@dir, 'harnesses'),
                 'ECOSYSTEM_REDIS_URL' => url, 'RUBYOPT' => nil, 'REDIS_URL' => nil }.merge(env)
    Open3.capture2e(full_env, SCRIPT)
  end

  def suite_started? = File.exist?(@log)

  def test_the_harness_db_on_a_private_server_runs
    out, status = run_script

    assert_predicate status, :success?, out
    assert_includes File.read(@log), "REDIS_URL=#{GOOD_URL}"
  end

  UNSAFE_URLS.each do |label, url|
    define_method("test_#{label.tr(' ', '_')}_aborts_before_any_suite") do
      out, status = run_script(url: url)

      refute_predicate status, :success?, out
      refute_predicate self, :suite_started?, out
    end
  end

  def test_without_a_url_a_throwaway_server_is_used_whatever_redis_url_says
    out, status = run_script(url: nil, env: { 'REDIS_URL' => 'redis://localhost:6379/0' })

    assert_predicate status, :success?, out
    url = File.read(@log)[/REDIS_URL=(\S+)/, 1]

    assert_match(%r{\Aredis://127\.0\.0\.1:\d+/15\z}, url)
    refute_includes url, ':6379/'
  end

  def test_a_killed_run_takes_its_throwaway_server_with_it
    pids = File.join(@dir, 'server.pid')
    stub('redis-server', %(echo $$ > "#{pids}"; exec sleep 30))
    stub('bundle', %(echo started >> "#{@log}"; exec sleep 30))
    env = { 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'ECOSYSTEM_HARNESS_DIR' => File.join(@dir, 'harnesses'),
            'ECOSYSTEM_REDIS_URL' => nil, 'RUBYOPT' => nil, 'REDIS_URL' => nil }
    script = Process.spawn(env, SCRIPT, %i[out err] => IO::NULL)
    sleep 0.05 until File.exist?(@log)
    server = Integer(File.read(pids))
    Process.kill('TERM', script)
    Process.wait(script)
    sleep 0.05 while alive?(server)

    refute alive?(server)
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def test_a_prepare_that_lost_its_exec_bit_aborts
    harness('some-gem', prepare: 'exit 0')
    File.chmod(0o644, File.join(@harness, 'prepare'))

    out, status = run_script

    refute_predicate status, :success?, out
    assert_includes out, 'not executable'
    refute_predicate self, :suite_started?
  end

  {
    'a url on db zero' => 'redis://127.0.0.1:6379/0',
    'a url with no db' => 'redis://127.0.0.1:6379',
    'a db chosen at runtime' => "redis://\#{host}/\#{db}",
    'the default port' => 'port: 6379',
    'a url with db zero in the query' => 'redis://h:1/15?db=0'
  }.each do |label, literal|
    define_method("test_a_drifted_prepare_leaving_#{label.tr(' ', '_')}_aborts") do
      body = "config = { a: \"#{literal}\" }"
      harness('some-gem', prepare: "mkdir -p spec/support; cat > spec/support/x.rb <<'RUBY'\n#{body}\nRUBY")

      out, status = run_script

      refute_predicate status, :success?, out
      assert_includes out, 'spec/support/x.rb:1'
      refute_predicate self, :suite_started?
    end
  end

  def test_a_harness_db_literal_is_fine
    harness('some-gem', prepare: "mkdir -p spec; echo 'x = \"redis://h:1/15\"' > spec/x.rb")

    out, status = run_script

    assert_predicate status, :success?, out
  end

  def test_an_allow_file_exempts_a_named_file_only
    harness('some-gem', prepare: "mkdir -p test; echo 'x = \"redis://h:1/0\"' > test/a.rb; cp test/a.rb test/b.rb")
    File.write(File.join(@harness, 'REDIS_SCAN_ALLOW'), "# a reason\ntest/a.rb\n")

    out, status = run_script

    refute_predicate status, :success?, out
    assert_includes out, 'test/b.rb:1'
    refute_includes out, 'test/a.rb:1'
  end

  def test_every_shipped_harness_with_a_prepare_keeps_its_exec_bit
    Dir[File.expand_path('../ecosystem/*/prepare', __dir__)].each do |prepare|
      assert_equal 'true', File.executable?(prepare).to_s, prepare
    end
  end

  def test_the_last_check_before_a_flush_reads_the_connection
    assert_nil EcosystemRedisGuard.check_connection!('id=1 addr=x db=15 sub=0')
    ['id=1 db=0 sub=0', 'id=1 db=1 sub=0', 'no such field'].each do |info|
      assert_raises(EcosystemRedisGuard::Unsafe) { EcosystemRedisGuard.check_connection!(info) }
    end
  end

  def test_the_guard_runs_from_the_command_line
    guard = File.expand_path('../ecosystem/redis_guard.rb', __dir__)
    _out, status = Open3.capture2e({ 'RUBYOPT' => nil }, RbConfig.ruby, guard, 'bogus')

    refute_predicate status, :success?
  end
end
