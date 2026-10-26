# frozen_string_literal: true

require 'minitest/autorun'
require 'json'

# bin/check's frontend stage exists to mirror test.yml's `frontend (vitest)`
# job, and the header of bin/check promises that a green local run is "the
# same answer the PR will get". That promise is only true while the two stay
# in step: drop a command from one side, reorder them, or typo a script name,
# and the gate quietly checks less than CI does — green locally, red on the
# PR, which is the exact failure the stage was added to prevent.
#
# So assert the mirror rather than trusting it. Reads files only; touches no
# Redis and no shared state.
class BinCheckFrontendParityTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  WORKFLOW = File.join(ROOT, '.github', 'workflows', 'test.yml')
  CHECK = File.join(ROOT, 'bin', 'check')

  # The `frontend:` job, up to the next job key at the same indentation.
  def frontend_job_lines
    lines = File.readlines(WORKFLOW)
    start = lines.index { |line| line.match?(/\A  frontend:\s*\z/) }
    return [] if start.nil?

    rest = lines[(start + 1)..] || []
    stop = rest.index { |line| line.match?(/\A  [a-z][\w-]*:\s*\z/) }
    stop ? rest[0...stop] : rest
  end

  # Every `run: bun ...` step in that job, in order.
  def ci_bun_commands
    frontend_job_lines.filter_map { |line| line[/\A\s+run:\s*(bun\s.+?)\s*\z/, 1] }
  end

  # The body of run_frontend_stage() in bin/check.
  def check_stage_lines
    lines = File.readlines(CHECK)
    start = lines.index { |line| line.match?(/\Arun_frontend_stage\(\)\s*\{/) }
    return [] if start.nil?

    rest = lines[(start + 1)..] || []
    stop = rest.index { |line| line.match?(/\A\}\s*\z/) }
    return [] if stop.nil?

    rest[0...stop]
  end

  # The same commands as ci_bun_commands, unwrapped from the `&&` chain and
  # its line continuations.
  def check_bun_commands
    check_stage_lines.filter_map do |line|
      cleaned = line.strip.sub(/\A&&\s*/, '').sub(/\s*\\\z/, '').strip
      cleaned if cleaned.start_with?('bun ')
    end
  end

  # Without this, deleting either side would make the comparison below pass
  # vacuously ([] == []) — a gate that reports green because it found nothing
  # to check is the failure mode this whole PR is about.
  def test_both_sides_this_gate_reads_still_exist
    refute_empty frontend_job_lines, 'test.yml must define a `frontend:` job'
    refute_empty check_stage_lines, 'bin/check must define run_frontend_stage()'
  end

  def test_ci_frontend_job_still_runs_bun_commands
    refute_empty ci_bun_commands,
                 "test.yml's frontend job must run at least one bun command — " \
                 'if it no longer does, this parity gate is checking nothing'
  end

  def test_bin_check_runs_exactly_the_ci_frontend_commands
    [ci_bun_commands, check_bun_commands].each do |commands|
      assert_includes commands, 'bun run test:coverage'
    end
    assert_equal ci_bun_commands, check_bun_commands,
                 "bin/check's frontend stage must run the same bun commands, in the same order, " \
                 "as test.yml's `frontend (vitest)` job — otherwise a green bin/check is not the " \
                 'answer the PR will get'
  end

  def test_coverage_script_and_dependencies_are_pinned_together
    manifest = JSON.parse(File.read(File.join(ROOT, 'frontend/package.json')))
    lock = File.read(File.join(ROOT, 'frontend/bun.lock'))
    workspace = lock.split('"packages":', 2).first

    assert_equal 'vitest run', manifest.fetch('scripts').fetch('test')
    assert_equal 'vitest run --coverage', manifest.fetch('scripts').fetch('test:coverage')

    %w[vitest @vitest/coverage-v8].each do |package|
      assert_equal '5.0.5', manifest.fetch('devDependencies').fetch(package)
      assert_includes workspace, "\"#{package}\": \"5.0.5\""
      assert_match(/"#{Regexp.escape(package)}": \["#{Regexp.escape(package)}@5\.0\.5"/, lock)
    end
  end

  def test_v8_counts_all_source_with_global_floors
    config = File.read(File.join(ROOT, 'frontend/vitest.config.ts'))
    coverage = config[/coverage:\s*\{(.*?)\n    \},/m, 1]

    refute_nil coverage
    assert_match(/provider:\s*'v8'/, coverage)
    assert_match(%r{include:\s*\['src/\*\*/\*\.\{ts,tsx\}'\]}, coverage)
    assert_match(
      %r{exclude:\s*\['src/\*\*/\*\.\{test,spec\}\.\{ts,tsx\}', 'src/test-setup\.ts'\]}, coverage
    )
    assert_match(/perFile:\s*false/, coverage)
    assert_match(/lines:\s*83\s*,/, coverage)
    assert_match(/branches:\s*66\s*,/, coverage)
  end

  def test_frontend_coverage_keeps_per_step_gating
    job = frontend_job_lines.join
    run = "${{ needs.detect.outputs.dup != 'true' && " \
          "(github.event_name != 'pull_request' || needs.detect.outputs.frontend == 'true') }}"

    steps = job.split(/^      - /).drop(1)
    coverage_step = steps.find { |step| step.include?('run: bun run test:coverage') }

    assert_includes job, "RUN: #{run}"
    refute_match(/^    if:/, job)
    refute_empty steps
    steps.each { |step| assert_match(/^        if: env\.RUN == 'true'$/, step) }
    refute_nil coverage_step
    assert_includes coverage_step, 'working-directory: frontend'
  end

  def test_both_sides_run_in_the_frontend_directory
    # CI sets working-directory per step; bin/check cds once in a subshell.
    working_dirs = frontend_job_lines.filter_map { |line| line[/\A\s+working-directory:\s*(\S+)\s*\z/, 1] }

    assert_includes working_dirs, 'frontend',
                    "test.yml's frontend job must run its steps in frontend/"
    assert(check_stage_lines.any? { |line| line.strip == 'cd frontend' },
           'run_frontend_stage() must cd into frontend/ before running bun')
  end
end
