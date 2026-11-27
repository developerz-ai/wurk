# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'socket'
require 'tmpdir'

# bin/check's Redis guard must look where the suite will connect: REDIS_URL,
# which lib/wurk and test_helper already read. When REDIS_URL is unset, the
# guard discovers the checkout's provisioned private endpoint via `bin/redis
# url`. When no private endpoint is provisioned, the guard exits 75 — it never
# falls back to shared Redis.
#
# A box whose Redis is not on 127.0.0.1:6379 (the developerz.ai fleet moves its
# sidecar off the well-known port so a repo's own store can bind it) must not
# be refused for a server the suite was never going to use.
#
# Drives the real script in `fast` mode with a stub `bundle` on PATH, so every
# stage past the guard is a no-op and the exit code is the guard's verdict.
class BinCheckRedisUrlTest < Minitest::Test
  parallelize_me!

  CHECK = File.expand_path('../../bin/check', __dir__)

  def run_check(redis_url, trace: false)
    Dir.mktmpdir do |dir|
      stub = File.join(dir, 'bundle')
      File.write(stub, "#!/usr/bin/env bash\nexit 0\n")
      File.chmod(0o755, stub)
      command = trace ? ['bash', '-x', CHECK] : [CHECK]
      Open3.capture3(check_env(dir, redis_url), *command, 'fast')
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

  # Rake turns test_helper's exit 75 into 1, so a held DB lock read as a failed suite.
  def test_a_suite_that_refused_to_start_reports_the_environment_not_the_diff
    Dir.mktmpdir do |dir|
      stub = File.join(dir, 'bundle')
      File.write(stub, <<~BASH)
        #!/usr/bin/env bash
        [ "$*" = 'exec rake test:unit' ] || exit 0
        echo 'DB 5 is held' > "$WURK_TEST_PRECONDITIONS_FILE"
        exit 1
      BASH
      File.chmod(0o755, stub)
      server = TCPServer.new('127.0.0.1', 0)
      url = "redis://127.0.0.1:#{server.addr[1]}/0"
      _out, err, status = Open3.capture3(check_env(dir, url), CHECK, 'fast')
      server.close

      assert_equal 75, status.exitstatus, err
    end
  end

  def test_a_real_failure_alongside_a_refusal_keeps_its_verdict
    Dir.mktmpdir do |dir|
      stub = File.join(dir, 'bundle')
      File.write(stub, <<~'BASH')
        #!/usr/bin/env bash
        case "$*" in
          exec\ rubocop*) exit 1 ;;
          'exec rake test:unit') echo held > "$WURK_TEST_PRECONDITIONS_FILE"; exit 1 ;;
        esac
      BASH
      File.chmod(0o755, stub)
      server = TCPServer.new('127.0.0.1', 0)
      _out, err, status = Open3.capture3(check_env(dir, "redis://127.0.0.1:#{server.addr[1]}/0"), CHECK, 'fast')
      server.close

      assert_equal 1, status.exitstatus, err
    end
  end

  def test_refuses_when_the_redis_url_server_is_down_and_names_it
    port = closed_port
    _out, err, status = run_check("redis://127.0.0.1:#{port}/0")

    assert_equal 75, status.exitstatus, err
    assert_includes err, "127.0.0.1:#{port}"
  end

  # Drive the real script in a throwaway checkout with REDIS_URL unset and a
  # stubbed `bin/redis url`, so the only endpoint it can discover is the one we
  # hand it. The stubbed bundle records the URL each stage actually receives.
  # `bundle check` is the gems precondition probe, run before the Redis guard,
  # so it cannot carry the discovered URL. Record only commands dispatched by
  # stage(), which are the stages the gate actually runs.
  STAGE_COMMANDS = [
    'exec rubocop --parallel',
    'exec bin/repin-anchors --check',
    'exec rake test:unit',
    'exec rake test',
    'exec rake test:parity'
  ].freeze

  def recorded_stages(log)
    return [] unless File.exist?(log)

    File.readlines(log, chomp: true).select { |line| STAGE_COMMANDS.include?(line.split('|').first) }
  end

  def run_unset_redis_check(redis_script:, mode: 'fast', trace: false)
    Dir.mktmpdir('check ') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'bin'))
      FileUtils.mkdir_p(File.join(dir, 'frontend'))
      FileUtils.cp(CHECK, File.join(dir, 'bin', 'check'))
      File.chmod(0o755, File.join(dir, 'bin', 'check'))

      log = File.join(dir, 'stage-urls.log')
      %w[bundle bun].each do |command|
        stub = File.join(dir, 'bin', command)
        File.write(stub, <<~'BASH')
          #!/usr/bin/env bash
          printf '%s|%s\n' "$*" "${REDIS_URL-unset}" >> "$CHECK_LOG"
          exit 0
        BASH
        File.chmod(0o755, stub)
      end

      redis_stub = File.join(dir, 'bin', 'redis')
      File.write(redis_stub, "#!/usr/bin/env bash\n#{redis_script}\n")
      File.chmod(0o755, redis_stub)

      # Under the full gate bin/check exports REDIS_URL into the suite process,
      # so Open3 would hand it straight back to the child. Clear it explicitly:
      # these tests must exercise discovery via the stubbed `bin/redis url`.
      env = { 'PATH' => "#{dir}/bin:#{ENV.fetch('PATH')}",
              'REDIS_URL' => nil, 'COVERAGE' => nil, 'CHECK_LOG' => log }
      command = trace ? ['bash', '-x', File.join(dir, 'bin', 'check')] : [File.join(dir, 'bin', 'check')]
      out, err, status = Open3.capture3(env, *command, mode)
      [out, err, status, recorded_stages(log)]
    end
  end

  # The guard probes the private endpoint and must hand the *full* URL to every
  # stage: test_helper otherwise falls back to shared localhost:6379. A stubbed
  # stage records what it actually received, so a probe-only fix cannot pass.
  def test_unset_redis_url_exports_provisioned_endpoint_to_every_stage
    server = TCPServer.new('127.0.0.1', 0)
    url = "redis://fixture-user:fixture-password@127.0.0.1:#{server.addr[1]}/7"
    out, err, status, stages = run_unset_redis_check(
      redis_script: "echo #{url}", mode: 'pr'
    )

    assert_equal 0, status.exitstatus, "#{out}\n#{err}"
    refute_empty stages, 'the gate must actually run stages'
    assert(stages.all? { |line| line.end_with?("|#{url}") },
           "every stage must receive the provisioned URL, got: #{stages.inspect}")
    assert_includes stages.map { |line| line.split('|').first }, 'exec rubocop --parallel'
    assert_includes stages.map { |line| line.split('|').first }, 'exec rake test'
    assert_includes stages.map { |line| line.split('|').first }, 'exec rake test:parity'
    assert_includes stages.map { |line| line.split('|').first }, 'exec bin/repin-anchors --check'
  ensure
    server&.close
  end

  # A provisioned URL can carry credentials. The guard needs host:port to probe,
  # but neither stdout nor any refusal may echo the password or the full URL.
  def test_provisioned_credentials_are_never_printed
    user = 'gate-user'
    password = 'gate-secret-value'
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    url = "redis://#{user}:#{password}@127.0.0.1:#{port}"
    out, err, status, = run_unset_redis_check(
      redis_script: "echo #{url}"
    )

    assert_equal 0, status.exitstatus, "#{out}\n#{err}"
    [out, err].each do |stream|
      refute_includes stream, password
      refute_includes stream, url
      refute_includes stream, "#{user}:#{password}"
    end
  ensure
    server&.close
  end

  def test_tracing_does_not_expose_discovered_credentials_and_resumes_after_export
    server = TCPServer.new('127.0.0.1', 0)
    url = "redis://trace-user:trace-password@127.0.0.1:#{server.addr[1]}/7"
    out, err, status, = run_unset_redis_check(redis_script: "echo #{url}", trace: true)

    assert_equal 0, status.exitstatus, "#{out}\n#{err}"
    [out, err].each do |stream|
      refute_includes stream, 'trace-user'
      refute_includes stream, 'trace-password'
    end
    assert_includes err, '+ stage '
  ensure
    server&.close
  end

  def test_credentialed_closed_port_refusal_never_prints_credentials
    port = closed_port
    url = "redis://refusal-user:refusal-password@127.0.0.1:#{port}/7"
    out, err, status, = run_unset_redis_check(redis_script: "echo #{url}")

    assert_equal 75, status.exitstatus, err
    assert_includes err, "127.0.0.1:#{port}"
    [out, err].each do |stream|
      refute_includes stream, 'refusal-user'
      refute_includes stream, 'refusal-password'
    end
  end

  def test_tracing_does_not_expose_explicit_credentials
    server = TCPServer.new('127.0.0.1', 0)
    url = "redis://explicit-user:explicit-password@127.0.0.1:#{server.addr[1]}/7"
    out, err, status = run_check(url, trace: true)

    assert_equal 0, status.exitstatus, "#{out}\n#{err}"
    [out, err].each do |stream|
      refute_includes stream, 'explicit-user'
      refute_includes stream, 'explicit-password'
    end
    assert_includes err, '+ stage '
  ensure
    server&.close
  end

  # When REDIS_URL is unset and no private endpoint is provisioned
  # (`bin/redis url` fails), the guard exits 75. It never falls back to
  # shared Redis, and the refusal names only host:port — never credentials.
  def test_unset_redis_url_no_private_endpoint_exits_75
    _out, err, status, stages = run_unset_redis_check(
      redis_script: 'exit 1'
    )

    assert_equal 75, status.exitstatus, err
    assert_empty stages, 'no stage may run when the prerequisite is missing'
    refute_includes err, 'localhost:6379'
    refute_includes err, 'redis://'
    assert_includes err, 'no private Redis endpoint is provisioned'
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

  def run_isolated_check(mode, coverage: nil, suite_exit: 0)
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
        'SUITE_EXIT' => suite_exit.to_s,
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
      assert_includes commands, 'bun run test|unset|present'
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
    assert_path_exists sentinel, "bin/check deleted the repo's coverage/ while the suite was writing to it"
  ensure
    server&.close
    FileUtils.rm_f(sentinel) if sentinel
    Dir.rmdir(coverage) if created && Dir.exist?(coverage) && Dir.empty?(coverage)
  end
end
