# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'socket'
require 'tmpdir'

# bin/check's Redis guard must look where the suite will connect: REDIS_URL,
# which lib/wurk and test_helper already read, falling back to the default.
# A box whose Redis is not on 127.0.0.1:6379 (the developerz.ai fleet moves its
# sidecar off the well-known port so a repo's own store can bind it) must not
# be refused for a server the suite was never going to use.
#
# Drives the real script in `fast` mode with a stub `bundle` on PATH, so every
# stage past the guard is a no-op and the exit code is the guard's verdict.
class BinCheckRedisUrlTest < Minitest::Test
  parallelize_me!

  CHECK = File.expand_path('../../bin/check', __dir__)

  def run_check(redis_url)
    Dir.mktmpdir do |dir|
      stub = File.join(dir, 'bundle')
      File.write(stub, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod(0o755, stub)
      Open3.capture3(check_env(dir, redis_url), CHECK, 'fast')
    end
  end

  # COVERAGE is unset for the child on purpose. Past the guards the real script
  # runs `rm -rf coverage` in the repo root whenever COVERAGE is set, and under
  # CI's COVERAGE=1 that repo root holds the resultsets of the suite running
  # this very test: inheriting it deleted every entry stored so far — a whole
  # worker's, if the other one had already finished — and the coverage gate then
  # failed a green suite at ~85%, depending on where the shuffle put this class.
  def check_env(dir, redis_url)
    { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'REDIS_URL' => redis_url, 'COVERAGE' => nil }
  end

  def closed_port
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    port
  end

  def test_refuses_when_the_redis_url_server_is_down_and_names_it
    port = closed_port
    _out, err, status = run_check("redis://127.0.0.1:#{port}/0")

    assert_equal 75, status.exitstatus, err
    assert_includes err, "127.0.0.1:#{port}"
  end

  # The unset-REDIS_URL fallback must be the suite's own default, byte for byte: a
  # guard that probes `127.0.0.1` while RedisPool connects to `localhost` can pass
  # or refuse over a server the suite never uses. Read, not run — the real 6379
  # on the box would otherwise decide the answer.
  def test_the_unset_fallback_is_the_suites_own_default
    suite_default = File.read(File.expand_path('../../lib/wurk/redis_pool.rb', __dir__))[
      /DEFAULT_URL\s*=\s*ENV\.fetch\('REDIS_URL', '([^']+)'\)/, 1
    ]

    refute_nil suite_default, 'RedisPool::DEFAULT_URL must still read REDIS_URL with a literal fallback'
    %w[bin/check bin/test-ecosystem].each do |script|
      fallback = File.read(File.expand_path("../../#{script}", __dir__))[/\$\{REDIS_URL:-([^}]+)\}/, 1]

      assert_equal suite_default, fallback, "#{script} must fall back to the suite's own default"
    end
  end

  def test_runs_the_gate_when_the_redis_url_server_answers
    server = TCPServer.new('127.0.0.1', 0)
    begin
      _out, err, status = run_check("redis://127.0.0.1:#{server.addr[1]}/3")

      assert_equal 0, status.exitstatus, err
    ensure
      server.close
    end
  end

  # Bites under COVERAGE=1 (CI), which is the only time the script deletes: a
  # file standing in the live coverage dir must outlive a gate run that gets
  # past the guards.
  def test_driving_the_gate_leaves_the_live_coverage_dir_alone
    coverage = File.expand_path('../../coverage', __dir__)
    created = !File.directory?(coverage)
    FileUtils.mkdir_p(coverage)
    sentinel = File.join(coverage, ".bin-check-sentinel-#{Process.pid}")
    File.write(sentinel, '')
    server = TCPServer.new('127.0.0.1', 0)

    _out, err, status = run_check("redis://127.0.0.1:#{server.addr[1]}/3")

    assert_equal 0, status.exitstatus, err
    assert_path_exists sentinel, "bin/check deleted the repo's coverage/ while the suite was writing to it"
  ensure
    server&.close
    FileUtils.rm_f(sentinel) if sentinel
    Dir.rmdir(coverage) if created && Dir.exist?(coverage) && Dir.empty?(coverage)
  end
end
