# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'

# Gates the two dup-aware rows of .dz/briefs/health.md (`main` is green,
# `topology and ecosystem lanes`) the way release_due_brief_test.rb gates
# release-due.md: these commands run unattended on a schedule, and a verdict
# they cannot actually establish must never be printed as a green one. Two
# properties, both pinned by RUNNING the extracted command cells as bash
# against a PATH-stubbed `gh` — a substring match over the brief's text would
# accept a guard that never fires:
#
#   1. FAIL CLOSED. `gh api .../actions/runs/<id>/jobs` is the only thing
#      between a `gh` error and a false green: with the read empty,
#      `[ "$dup" = true ]` is false and the row falls through to grading on
#      `conclusion`, printing `success <sha>` for a run that executed nothing.
#   2. The dup signature REQUIRES `detect changed paths` to conclude success.
#      A failed or cancelled detect publishes no outputs, `needs:` skips every
#      dependent, and the job list comes back all-skipped with no dup in it.
#
# Reads the brief and runs its own extracted commands; no network, no Redis,
# no shared state.
class HealthBriefTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  BRIEF = File.join(ROOT, '.dz', 'briefs', 'health.md')

  SHA_DUP       = 'd' * 40
  SHA_GREEN     = 'a' * 40
  SHA_TOPOLOGY  = 'c' * 40
  SHA_ECOSYSTEM = 'e' * 40

  def setup
    @text = File.read(BRIEF)
  end

  def test_dup_push_run_with_every_gated_job_skipped_grades_unhealthy
    out, err, status = run_row8(jobs: jobs_json(detect: 'success', gated: 'skipped'),
                                conclusion: 'success', sha: SHA_DUP)

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Unhealthy',
                    'a run whose `detect changed paths` concluded success and whose ' \
                    'every other job came back `skipped` IS a dup\'d push — it must ' \
                    'grade Unhealthy even though conclusion=success; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, SHA_DUP,
                    'the Unhealthy verdict must surface the dup\'d headSha: that ' \
                    'coverage came from the PR run, so main has no signal of its ' \
                    "own and the ask has to name the sha; got stdout=#{out.inspect}"

    refute_includes out, 'verdict unknown',
                    'a readable jobs list is a verdict, not an unknown'
  end

  def test_run_whose_gated_jobs_actually_ran_grades_on_conclusion
    out, err, status = run_row8(jobs: jobs_json(detect: 'success', gated: 'success'),
                                conclusion: 'success', sha: SHA_GREEN)

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["success #{SHA_GREEN}"], out.lines.map(&:chomp),
                 'gated jobs that really ran make this an ordinary main run: the ' \
                 'row grades on conclusion and prints exactly `success <sha>`'

    refute_includes out, 'Unhealthy',
                    'a run whose gated jobs succeeded is not a dup'
    refute_includes out, 'verdict unknown',
                    'a readable jobs list is a verdict, not an unknown'
  end

  def test_unreadable_jobs_list_never_grades_success
    out, err, _status = run_row8(jobs: jobs_json(detect: 'success', gated: 'skipped'),
                                 conclusion: 'success', sha: SHA_DUP, jobs_fail: true)

    refute_includes out, "success #{SHA_DUP}",
                    'the `gh api .../jobs` stub failed, so the jobs list is ' \
                    'unreadable and the row knows nothing about what ran; it must ' \
                    'not fall through to grading on conclusion and print a false ' \
                    "green (stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'verdict unknown',
                    'an unreadable jobs list must surface as `verdict unknown` so ' \
                    "the next checkup re-runs it; got stdout=#{out.inspect}"

    assert_includes out, SHA_DUP,
                    '`verdict unknown` must still name the sha it could not grade, ' \
                    "so the ask can link the run; got stdout=#{out.inspect}"
  end

  def test_failed_detect_is_not_read_as_a_dup
    # The counterexample to "all-skipped means dup and nothing else": a `detect`
    # that fails or is cancelled publishes no outputs, `needs:` then skips every
    # dependent, and the job list comes back all-skipped with no dup anywhere in
    # it. The run's own conclusion is `failure`, and that — not a dup'd PR run —
    # is why nothing ran.
    out, err, status = run_row8(jobs: jobs_json(detect: 'failure', gated: 'skipped'),
                                conclusion: 'failure', sha: SHA_DUP)

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["failure #{SHA_DUP}"], out.lines.map(&:chomp),
                 'a failed `detect` skips every dependent via `needs:` and yields ' \
                 'the same all-skipped job list, so the dup signature must require ' \
                 "detect's own success; got stdout=#{out.inspect}"
  end

  def test_row12_names_the_offending_workflow
    # topology.yml is the dup'd lane, ecosystem.yml ran its gated job: the ask
    # has to name WHICH lane went unverified, or the reader cannot tell which
    # workflow to go look at.
    out, err, status = run_row12

    assert_predicate status, :success?,
                     "row 12's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)
    unhealthy = lines.select { |line| line.include?('Unhealthy') }

    assert_equal 1, unhealthy.size,
                 "exactly one of the two lanes must grade Unhealthy; got #{lines.inspect}"

    assert_includes unhealthy.first, 'topology.yml',
                    "the Unhealthy line must name topology.yml; got #{unhealthy.first.inspect}"

    refute_includes unhealthy.first, 'ecosystem.yml',
                    'the Unhealthy line must not name ecosystem.yml, which ran its ' \
                    "gated job; got #{unhealthy.first.inspect}"

    assert_includes unhealthy.first, SHA_TOPOLOGY,
                    "the Unhealthy line must carry topology.yml's own headSha; got " \
                    "#{unhealthy.first.inspect}"

    assert_includes lines, "ecosystem.yml success #{SHA_ECOSYSTEM}",
                    'the healthy lane still grades on its own conclusion and reports ' \
                    "its own sha; got #{lines.inspect}"
  end

  private

  # A `gh api repos/.../actions/runs/<id>/jobs` response shaped like the real
  # one: `detect changed paths` plus the gated jobs reading
  # `needs.detect.outputs`. `sidekiq release watcher` is ecosystem.yml's
  # schedule/dispatch-only job — it is skipped on every push, which is why
  # row 12 excludes it by name.
  def jobs_json(detect:, gated:)
    jobs = [{ 'name' => 'detect changed paths', 'conclusion' => detect },
            { 'name' => 'test + coverage (latest ruby/rails)', 'conclusion' => gated },
            { 'name' => 'lint (rubocop)', 'conclusion' => gated },
            { 'name' => 'sidekiq release watcher', 'conclusion' => 'skipped' }]

    JSON.generate('total_count' => jobs.size, 'jobs' => jobs)
  end

  def write_fixture(dir, name, body)
    File.write(File.join(dir, name), body)
  end

  # The `Command` cell of the row whose Signal cell contains `signal`.
  # Cells are `|`-separated and both of these commands are full of shell
  # pipes, so the cell is cut at its backticks instead: the command opens at
  # the last backtick before its own `gh run list` and closes at the next one
  # after it. `\|` is markdown's escape for a literal pipe inside a cell.
  def command_cell(signal)
    row = @text.lines.find { |line| line.include?(signal) && line.include?('gh run list') }
    raise "health.md has no row for #{signal.inspect} that calls `gh run list`" if row.nil?

    open_at = row.rindex('`', row.index('gh run list'))
    raise "no opening backtick before `gh run list` on the #{signal.inspect} row" if open_at.nil?

    close_at = row.index('`', open_at + 1)
    raise "no closing backtick for the Command cell on the #{signal.inspect} row" if close_at.nil?

    row[(open_at + 1)...close_at].gsub('\\|', '|')
  end

  def run_row8(jobs:, conclusion:, sha:, jobs_fail: false)
    run_command(command_cell('`main` is green'), jobs_fail: jobs_fail) do |fixtures|
      write_fixture(fixtures, 'test.yml.dbid', '1')
      write_fixture(fixtures, 'test.yml.sha', sha)
      write_fixture(fixtures, 'test.yml.conclusion', conclusion)
      write_fixture(fixtures, 'dbid-1.jobs', jobs)
    end
  end

  def run_row12(jobs_fail: false)
    run_command(command_cell('topology and ecosystem lanes'), jobs_fail: jobs_fail) do |fixtures|
      write_fixture(fixtures, 'topology.yml.dbid', '101')
      write_fixture(fixtures, 'topology.yml.sha', SHA_TOPOLOGY)
      write_fixture(fixtures, 'topology.yml.conclusion', 'success')
      write_fixture(fixtures, 'dbid-101.jobs', jobs_json(detect: 'success', gated: 'skipped'))

      write_fixture(fixtures, 'ecosystem.yml.dbid', '102')
      write_fixture(fixtures, 'ecosystem.yml.sha', SHA_ECOSYSTEM)
      write_fixture(fixtures, 'ecosystem.yml.conclusion', 'success')
      write_fixture(fixtures, 'dbid-102.jobs', jobs_json(detect: 'success', gated: 'success'))
    end
  end

  # Runs a brief command as a stand-alone Bash script with a stub `gh` first
  # on PATH. The script is NOT prefixed with `set -euo pipefail` — the brief
  # enables no shell options, and injecting them would mask a regression that
  # swallows the failing `gh api` inside a pipeline. Yields the fixtures dir
  # before the script runs so the caller can write the job lists the stub
  # serves, then returns Open3's [stdout, stderr, status].
  def run_command(command, jobs_fail:)
    Dir.mktmpdir('wurk-health-brief-') do |tmpdir|
      fixtures = File.join(tmpdir, 'fixtures')
      bin_dir = File.join(tmpdir, 'bin')
      Dir.mkdir(fixtures)
      Dir.mkdir(bin_dir)

      yield fixtures

      gh_path = File.join(bin_dir, 'gh')
      File.write(gh_path, STUB_GH)
      File.chmod(0o755, gh_path)

      script_path = File.join(tmpdir, 'health.sh')
      File.write(script_path, "#!/usr/bin/env bash\n#{command}\n")
      File.chmod(0o755, script_path)

      env = {
        'PATH' => "#{bin_dir}:#{ENV.fetch('PATH', '')}",
        'WURK_TEST_FIXTURES' => fixtures,
        'WURK_TEST_JOBS_FAIL' => jobs_fail ? '1' : '0'
      }

      Open3.capture3(env, script_path)
    end
  end

  # Stub `gh`. Every answer is read from the fixture dir the test wrote, so
  # the brief's command runs against a fixed jobs list instead of the API.
  # `WURK_TEST_JOBS_FAIL=1` makes ONLY the jobs call fail, leaving the run
  # list readable — that is the exact shape of the false green this file
  # pins: a `conclusion` the brief can see, and a jobs list it cannot.
  STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    fixdir="$WURK_TEST_FIXTURES"
    case "${1:-}" in
      run)
        wf=""
        for arg in "$@"; do
          case "$arg" in
            *.yml) wf="$arg" ;;
          esac
        done
        if [ -z "$wf" ]; then
          printf 'stub gh run: no --workflow argument in: %s\n' "$*" >&2
          exit 1
        fi
        printf '[{"databaseId":%s,"headSha":"%s","conclusion":"%s"}]\n' \
          "$(cat "$fixdir/$wf.dbid")" \
          "$(cat "$fixdir/$wf.sha")" \
          "$(cat "$fixdir/$wf.conclusion")"
        ;;
      repo)
        printf 'wurk-owner/wurk\n'
        ;;
      api)
        if [ "$WURK_TEST_JOBS_FAIL" = "1" ]; then
          printf 'stub gh api: the jobs call fails on purpose (rate limited or 4xx)\n' >&2
          exit 1
        fi
        url=""
        for arg in "$@"; do
          case "$arg" in
            *'/actions/runs/'*'/jobs') url="$arg" ;;
          esac
        done
        dbid="${url##*/actions/runs/}"
        dbid="${dbid%/jobs}"
        if [ ! -s "$fixdir/dbid-$dbid.jobs" ]; then
          printf 'stub gh api: no jobs fixture for databaseId %s (URL %s)\n' "$dbid" "$url" >&2
          exit 1
        fi
        cat "$fixdir/dbid-$dbid.jobs"
        ;;
      *)
        printf 'stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :STUB_GH
end
