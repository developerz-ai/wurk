# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# Gates the `python-client` job of .github/workflows/test.yml — the job whose
# required check is literally named `python-client (3.9)`, so every property
# pinned here is also a branch-protection property.
#
# Why it exists: the job ran on `ubuntu-latest`, the label moved to Ubuntu
# 26.04, and actions/python-versions publishes no linux-26.04 build for Python
# 3.9 (its newest 3.9 release lists linux-22.04 and linux-24.04 only). Run
# 42348193660 failed with "The version '3.9' with architecture 'x64' was not
# found for Ubuntu 26.04." on `main`, because nothing in the suite read this
# job at all — the only runner assertion in the repo pins release-smoke.yml.
# The image is now pinned to ubuntu-24.04, and this guard turns the next
# `ubuntu-latest` migration into a review failure instead of a red main.
#
# The migration temptations are pinned too, because each one silently deletes
# coverage rather than failing: dropping "3.9" from the matrix (the matrix
# label is in the required check's name, so the check would never report),
# pinning the interpreter to one version inside setup-python (the 3.13 leg
# would silently run 3.9), and `continue-on-error` on any step (the job goes
# green while its tests are red). Each mutation case below proves the guard
# can actually fail for the regression it names.
#
# Reads files; touches no Redis, no network and no shared state.
class PythonClientWorkflowTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  TEST_YML = File.join(ROOT, '.github', 'workflows', 'test.yml')

  JOB = 'python-client'
  # The gated check's name. Branch protection requires `python-client (3.9)`,
  # which only exists while the matrix supplies the suffix.
  JOB_NAME = 'python-client (${{ matrix.python-version }})'
  VERSIONS = %w[3.9 3.13].freeze

  # The newest image actions/python-versions still publishes a Python 3.9 build
  # for. The image's own toolcache carries 3.11-3.15 only, so setup-python
  # downloads python-3.9.25-linux-24.04-x64.tar.gz on a miss.
  RUNNER = 'ubuntu-24.04'
  # The moving label: it followed Ubuntu to 26.04 and took 3.9 with it.
  MOVING_RUNNER = 'ubuntu-latest'

  # The interpreter comes from the matrix. A literal here would collapse both
  # legs onto one version while the check names still claim two.
  VERSION_SELECTION = '${{ matrix.python-version }}'

  INSTALL_COMMAND = 'pip install ./clients/python'
  TEST_COMMAND = 'python -m unittest discover -s clients/python/tests -v'
  # Gated per step, never per job: a skipped step still lets the job report,
  # and a job-level `if:` would skip the required check itself.
  STEP_GATE = "env.RUN == 'true'"

  # --- the job as it is ----------------------------------------------------

  def test_the_python_client_job_still_exists_and_keeps_its_name
    job = python_client_job

    assert_equal JOB_NAME, job['name'],
                 'the job name carries the matrix version, and `python-client (3.9)` is the required ' \
                 'check — renaming it leaves branch protection requiring a check that never reports'
  end

  def test_the_matrix_still_runs_both_python_versions
    assert_matrix_runs_both_versions(python_client_job)
  end

  def test_the_runner_is_pinned_instead_of_following_ubuntu_latest
    assert_runner_pinned(python_client_job)
  end

  def test_setup_python_takes_the_interpreter_from_the_matrix
    assert_setup_python_uses_the_matrix(python_client_job)
  end

  def test_both_client_steps_are_unchanged
    assert_both_client_steps(python_client_job)
  end

  def test_no_step_silences_a_failure
    assert_no_continue_on_error(python_client_job)
  end

  def test_every_step_is_gated_individually_so_the_job_always_reports
    assert_every_step_gated(python_client_job)
  end

  # --- the mutations the guard exists for ----------------------------------

  # The defect that took main red: the moving label followed Ubuntu to 26.04.
  def test_guard_rejects_a_runner_that_follows_ubuntu_latest
    job = job_copy
    job['runs-on'] = MOVING_RUNNER

    error = assert_raises(Minitest::Assertion) { assert_runner_pinned(job) }

    assert_includes error.message, MOVING_RUNNER,
                    'the guard must say the label is the problem, not just that some image is wrong'
  end

  # The tempting "fix" for the missing 3.9 build: drop 3.9 from the matrix.
  # That deletes the required check's name instead of its failure.
  def test_guard_rejects_a_matrix_that_dropped_python_39
    job = job_copy
    versions = job.fetch('strategy').fetch('matrix').fetch('python-version')
    versions.delete('3.9')

    refute_includes versions, '3.9', 'the mutation did not apply — the matrix no longer lists 3.9'

    error = assert_raises(Minitest::Assertion) { assert_matrix_runs_both_versions(job) }

    assert_includes error.message, '3.9'
  end

  # The other tempting fix: pin the interpreter inside setup-python. Both
  # matrix legs then run the same version while the names still claim two.
  def test_guard_rejects_a_literal_interpreter_pin_before_the_matrix
    job = job_copy
    setup_python_step(job)['with']['python-version'] = '3.9'

    error = assert_raises(Minitest::Assertion) { assert_setup_python_uses_the_matrix(job) }

    assert_includes error.message, VERSION_SELECTION
  end

  # A step that cannot fail this job: the tests run red, the required check
  # still reports green.
  def test_guard_rejects_continue_on_error_on_any_step
    job = job_copy
    job.fetch('steps').last['continue-on-error'] = true

    error = assert_raises(Minitest::Assertion) { assert_no_continue_on_error(job) }

    assert_includes error.message, 'continue-on-error'
  end

  def test_guard_rejects_a_dropped_test_command
    job = job_copy
    job['steps'] = steps(job).reject { |step| step['run'].to_s.strip == TEST_COMMAND }

    error = assert_raises(Minitest::Assertion) { assert_both_client_steps(job) }

    assert_includes error.message, TEST_COMMAND
  end

  # --- helpers -------------------------------------------------------------

  private

  def workflow
    @workflow ||= YAML.load_file(TEST_YML)
  end

  def python_client_job
    workflow.fetch('jobs').fetch(JOB) do
      flunk "test.yml lost its `#{JOB}` job — its required check `python-client (3.9)` would vanish"
    end
  end

  def steps(job)
    job.fetch('steps')
  end

  def setup_python_step(job)
    step = steps(job).find { |step| step['uses'].to_s.start_with?('actions/setup-python@') }
    return step if step

    flunk('the `python-client` job lost its actions/setup-python step')
  end

  # The job as a mutable copy, for the mutation cases: the real file stays
  # untouched while each gate is proven to reject a regression.
  def job_copy
    deep_dup(python_client_job)
  end

  def deep_dup(object)
    case object
    when Hash then object.to_h { |key, value| [key, deep_dup(value)] }
    when Array then object.map { |value| deep_dup(value) }
    else object
    end
  end

  def assert_matrix_runs_both_versions(job)
    versions = job.dig('strategy', 'matrix', 'python-version')

    VERSIONS.each do |version|
      assert_includes Array(versions), version,
                      "the matrix must keep \"#{version}\": the required check is named " \
                      "`#{JOB} (#{version})`, so dropping it silently deletes the check " \
                      'instead of failing it'
    end
  end

  def assert_runner_pinned(job)
    runner = job['runs-on']

    refute_equal MOVING_RUNNER, runner,
                 "`#{JOB}` must not run on `#{MOVING_RUNNER}`: the label follows Ubuntu forward, and " \
                 'actions/python-versions publishes no linux-26.04 build for Python 3.9 — run ' \
                 '42348193660 failed here with "The version \'3.9\' with architecture \'x64\' was ' \
                 'not found for Ubuntu 26.04."'
    assert_equal RUNNER, runner,
                 "`#{JOB}` must run on #{RUNNER}, the newest image actions/python-versions still " \
                 'publishes a Python 3.9 build for (setup-python downloads it on a toolcache ' \
                 'miss); any other image is unproven for the 3.9 leg'
  end

  def assert_setup_python_uses_the_matrix(job)
    step = setup_python_step(job)
    selection = step.dig('with', 'python-version') || step.dig('with', 'python_version')

    assert_equal VERSION_SELECTION, selection,
                 "actions/setup-python must take `python-version: #{VERSION_SELECTION}` — a literal " \
                 'pin collapses both matrix legs onto one interpreter while the check names still ' \
                 'claim two versions'
  end

  def assert_both_client_steps(job)
    runs = steps(job).map { |step| step.fetch('run', '').strip }

    assert_includes runs, INSTALL_COMMAND,
                    "the `#{JOB}` job must still install the client with `#{INSTALL_COMMAND}`"
    assert_includes runs, TEST_COMMAND,
                    "the `#{JOB}` job must still run its suite with `#{TEST_COMMAND}`"
  end

  def assert_no_continue_on_error(job)
    offenders = steps(job).select { |step| step.key?('continue-on-error') }
                          .map { |step| step['name'] || step['uses'] }

    assert_empty offenders,
                 "no step of `#{JOB}` may set `continue-on-error`: the required check would report " \
                 'green while the client\'s tests are red'
  end

  # A job-level `if:` would skip the required check itself, and a step with no
  # gate would run (and fail) on a change that cannot affect it.
  def assert_every_step_gated(job)
    ungated = steps(job).reject { |step| step['if'] == STEP_GATE }
                        .map { |step| step['name'] || step['uses'] }

    assert_empty ungated,
                 "every step of `#{JOB}` must carry `if: #{STEP_GATE}` — gate per step, never per " \
                 'job, so the required check always runs and reports'
  end
end
