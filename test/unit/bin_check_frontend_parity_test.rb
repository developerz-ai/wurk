# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'yaml'

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
    assert_equal ci_bun_commands, check_bun_commands,
                 "bin/check's frontend stage must run the same bun commands, in the same order, " \
                 "as test.yml's `frontend (vitest)` job — otherwise a green bin/check is not the " \
                 'answer the PR will get'
  end

  def test_coverage_command_is_required_even_if_both_sides_drift
    assert_equal ['bun install --frozen-lockfile', 'bun run typecheck', 'bun run lint', 'bun run test:coverage'],
                 ci_bun_commands
  end

  def test_frontend_job_keeps_its_run_expression_and_per_step_guards
    job = YAML.safe_load(File.read(WORKFLOW)).fetch('jobs').fetch('frontend')

    assert_equal 'frontend (vitest)', job.fetch('name')
    refute job.key?('if'), 'required frontend job must report even for filtered changes'
    assert_equal "${{ needs.detect.outputs.dup != 'true' && (github.event_name != 'pull_request' || needs.detect.outputs.frontend == 'true') }}",
                 job.fetch('env').fetch('RUN')
    steps = job.fetch('steps')

    refute_empty steps
    steps.each do |step|
      assert_equal "env.RUN == 'true'", step.fetch('if'), step.inspect
      assert_equal 'frontend', step.fetch('working-directory') if step.fetch('run', '').start_with?('bun ')
    end
  end

  def test_coverage_script_and_provider_versions_are_pinned_together
    package = JSON.parse(File.read(File.join(ROOT, 'frontend/package.json')))

    assert_equal 'vitest run', package.fetch('scripts').fetch('test')
    assert_equal 'vitest run --coverage', package.fetch('scripts').fetch('test:coverage')
    lock = File.read(File.join(ROOT, 'frontend/bun.lock'))
    workspace = lock.split('"packages":', 2).first
    %w[vitest @vitest/coverage-v8].each do |name|
      assert_equal '5.0.5', package.fetch('devDependencies').fetch(name)
      assert_match(/"#{Regexp.escape(name)}":\s*"5\.0\.5"/, workspace)
      assert_match(/"#{Regexp.escape(name)}":\s*\["#{Regexp.escape(name)}@5\.0\.5"/, lock)
    end
  end

  def test_v8_coverage_counts_all_source_with_global_floors
    config = File.read(File.join(ROOT, 'frontend/vitest.config.ts'))
    coverage = config[/coverage:\s*\{(.*?)\n    \},/m, 1]

    refute_nil coverage, 'Vitest must configure coverage'
    assert_match(/provider:\s*'v8'/, coverage)
    assert_match(/include:\s*\['src\/\*\*\/\*\.\{ts,tsx\}'\]/, coverage)
    assert_match(/exclude:\s*\['src\/\*\*\/\*\.\{test,spec\}\.\{ts,tsx\}', 'src\/test-setup\.ts'\]/, coverage)
    thresholds = coverage[/thresholds:\s*\{([^}]+)\}/, 1]

    refute_nil thresholds, 'coverage must enforce thresholds'
    assert_match(/perFile:\s*false\s*,/, thresholds)
    assert_match(/lines:\s*83\s*,/, thresholds)
    assert_match(/branches:\s*66\s*,/, thresholds)
    refute_match(/(?:enabled|reportOnFailure):\s*false|ignoreEmptyLines:\s*true/, coverage)
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
