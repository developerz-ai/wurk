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

  def run_isolated_check(mode, coverage: nil, suite_exit: 0, frontend_exit: 0)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'bin'))
      FileUtils.mkdir_p(File.join(dir, 'frontend'))
      FileUtils.mkdir_p(File.join(dir, 'coverage'))
      FileUtils.cp(CHECK, File.join(dir, 'bin/check'))
      File.write(File.join(dir, 'coverage/stale'), 'old resultset')
      write_isolated_stubs(dir)
      server = TCPServer.new('127.0.0.1', 0)
      env = check_env(File.join(dir, 'bin'), "redis://127.0.0.1:#{server.addr[1]}/3").merge(
        'COVERAGE' => coverage, 'CHECK_ROOT' => dir, 'CHECK_LOG' => File.join(dir, 'commands.log'),
        'SUITE_EXIT' => suite_exit.to_s, 'FRONTEND_EXIT' => frontend_exit.to_s,
        'SKIP_LINT' => nil, 'SKIP_FRONTEND' => nil, 'SKIP_PARITY' => nil
      )
      out, err, status = Open3.capture3(env, File.join(dir, 'bin/check'), *Array(mode))
      [out, err, status, File.readlines(env.fetch('CHECK_LOG'), chomp: true)]
    ensure
      server&.close
    end
  end

  def write_isolated_stubs(dir)
    %w[bundle bun python3].each do |command|
      stub = File.join(dir, 'bin', command)
      File.write(stub, <<~'BASH')
        #!/usr/bin/env bash
        stale=absent
        [ ! -e "$CHECK_ROOT/coverage/stale" ] || stale=present
        printf '%s|%s|%s\n' "${0##*/} $*" "${COVERAGE-unset}" "$stale" >> "$CHECK_LOG"
        if [ "${0##*/} $*" = 'bundle exec rake test' ] && [ "${COVERAGE-unset}" = 1 ]; then
          exit "$SUITE_EXIT"
        fi
        if [ "${0##*/} $*" = 'bun run test:coverage' ]; then
          exit "$FRONTEND_EXIT"
        fi
        exit 0
      BASH
      File.chmod(0o755, stub)
    end
  end

  def test_default_pr_and_full_require_fresh_suite_coverage_only
    [nil, 'pr', 'full'].each do |mode|
      out, err, status, commands = run_isolated_check(mode)

      assert_equal 0, status.exitstatus, "#{mode.inspect}: #{out}\n#{err}"
      assert_includes commands, 'bundle exec rake test|1|absent'
      assert_includes commands, 'bundle exec rake test:parity|unset|absent'
      assert_includes commands, 'bundle exec rubocop --parallel|unset|present'
      assert_includes commands, 'bun run test:coverage|unset|present'
      other_stages = commands.reject { |line| line.start_with?('bundle exec rake test|') }

      assert_equal ['unset'], other_stages.map { |line| line.split('|')[1] }.uniq, commands.inspect
      assert_includes commands, 'bundle exec rake test:ecosystem|unset|absent' if mode == 'full'
    end
  end

  def test_coverage_enabled_suite_failure_fails_the_gate
    out, err, status, commands = run_isolated_check('pr', suite_exit: 23)

    assert_equal 1, status.exitstatus, "#{out}\n#{err}"
    assert_includes commands, 'bundle exec rake test|1|absent'
    assert_includes out, '✗ test suite (unit + integration + engine)'
    assert_includes err, 'bin/check ✗ failed: test suite (unit + integration + engine)'
    assert_includes commands, 'bundle exec rake test:parity|unset|absent'
  end

  def test_frontend_coverage_failure_fails_the_gate
    out, err, status, commands = run_isolated_check('pr', frontend_exit: 23)

    assert_equal 1, status.exitstatus, "#{out}\n#{err}"
    assert_includes commands, 'bun run test:coverage|unset|present'
    assert_includes out, '✗ frontend'
    assert_includes err, 'bin/check ✗ failed: frontend'
    assert_includes commands, 'bundle exec rake test|1|absent'
  end

  def test_fast_coverage_remains_opt_in
    { nil => 'unset|present', '1' => '1|absent' }.each do |coverage, expected|
      out, err, status, commands = run_isolated_check('fast', coverage: coverage)

      assert_equal 0, status.exitstatus, "#{out}\n#{err}"
      assert_includes commands, "bundle exec rake test:unit|#{expected}"
      refute_includes commands.map { |line| line.split('|').first }, 'bundle exec rake test:parity'
    end
  end

  # Both real fast-mode and isolated mandatory-coverage children must leave the
  # parent's live resultsets alone, including when this test runs under coverage.
  def test_driving_the_gate_leaves_the_live_coverage_dir_alone
    coverage = File.expand_path('../../coverage', __dir__)
    created = !File.directory?(coverage)
    FileUtils.mkdir_p(coverage)
    sentinel = File.join(coverage, ".bin-check-sentinel-#{Process.pid}")
    File.write(sentinel, '')
    server = TCPServer.new('127.0.0.1', 0)

    _out, err, status = run_check("redis://127.0.0.1:#{server.addr[1]}/3")

    assert_equal 0, status.exitstatus, err
    _out, err, status, = run_isolated_check('pr')

    assert_equal 0, status.exitstatus, err
    _out, err, status, = run_isolated_check('pr', frontend_exit: 23)

    assert_equal 1, status.exitstatus, err
    assert_path_exists sentinel, "bin/check deleted the repo's coverage/ while the suite was writing to it"
  ensure
    server&.close
    FileUtils.rm_f(sentinel) if sentinel
    Dir.rmdir(coverage) if created && Dir.exist?(coverage) && Dir.empty?(coverage)
  end
end
