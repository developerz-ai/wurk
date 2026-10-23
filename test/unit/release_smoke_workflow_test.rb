# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# Gates the contract of .github/workflows/release-smoke.yml — the reusable
# workflow that smoke-checks a PUBLISHED wurk gem from a consumer's side.
#
# The workflow is the release lane's only end-to-end evidence, and it runs
# AFTER the irreversible `gem push`: nothing it reports can be rolled back, so
# the only defence against it quietly degrading is a gate on what it must
# contain. This test pins that contract:
#
#   * it is callable from release.yml AND dispatchable by hand, each with a
#     required `version` input — the whole workflow is meaningless without a
#     version to verify;
#   * it exposes a `smoke_ok` output wired to the job's own output, so a
#     caller can branch on it;
#   * it runs on ubuntu-latest with a redis:7.4 service and a job timeout;
#   * every failure path emits its OWN `::error::` diagnostic naming the unmet
#     condition — a shared or generic message tells a maintainer nothing;
#   * it contains NO rollback or compensation step. The publish tail is
#     irreversible by design, so the smoke is post-publish evidence only;
#   * every process that boots the throwaway Rails app gets a REAL
#     SECRET_KEY_BASE. SECRET_KEY_BASE_DUMMY is Wurk's "this is a build step"
#     marker (RailsBoot#building?), not the secret Rails reads in production;
#   * WURK_DISABLED=1 lands only on the processes that must not fork a swarm
#     of their own — the swarm process itself must not carry it.
#
# Reads files; touches no Redis, no network and no shared state.
class ReleaseSmokeWorkflowTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  SMOKE_YML = File.join(ROOT, '.github', 'workflows', 'release-smoke.yml')
  RELEASE_YML = File.join(ROOT, '.github', 'workflows', 'release.yml')

  # --- triggers and inputs ------------------------------------------------

  def test_declares_both_workflow_call_and_workflow_dispatch
    triggers = smoke_triggers

    assert_includes triggers.keys, 'workflow_call',
                    'release-smoke.yml must stay callable as a reusable workflow (release.yml calls it)'
    assert_includes triggers.keys, 'workflow_dispatch',
                    'release-smoke.yml must stay dispatchable by hand so any published release can be checked'
  end

  # A smoke run without a version has nothing to verify, so the input is
  # required on BOTH triggers — not optional with a default.
  def test_every_trigger_requires_a_version_input
    smoke_triggers.each do |name, trigger|
      inputs = trigger.fetch('inputs', {})

      assert_includes inputs.keys, 'version', "#{name} must accept a `version` input"
      assert inputs.fetch('version').fetch('required'),
             "#{name}'s `version` input must be required — a smoke run with no version verifies nothing"
    end
  end

  # --- the smoke_ok output -------------------------------------------------

  def test_exposes_a_smoke_ok_output_wired_to_the_job_output
    call_outputs = smoke_triggers.fetch('workflow_call').fetch('outputs', {})

    assert_includes call_outputs.keys, 'smoke_ok',
                    'workflow_call must expose a `smoke_ok` output so a caller can branch on the result'
    assert_equal '${{ jobs.smoke.outputs.smoke_ok }}', call_outputs.dig('smoke_ok', 'value'),
                 'the `smoke_ok` output must be wired to the job\'s own `smoke_ok` output'

    job_outputs = smoke_job.fetch('outputs', {})

    assert_includes job_outputs.keys, 'smoke_ok', 'the `smoke` job must expose a `smoke_ok` output'
    assert_equal '${{ steps.result.outputs.ok }}', job_outputs['smoke_ok'],
                 "the job's `smoke_ok` output must come from the `result` step"
  end

  # --- the job's environment ----------------------------------------------

  def test_job_runs_on_ubuntu_latest_with_a_redis_service_and_a_timeout
    assert_equal 'ubuntu-latest', smoke_job['runs-on']

    assert smoke_job.key?('timeout-minutes'),
           'the `smoke` job must carry a `timeout-minutes` — an unbounded job would hang a release run forever'

    redis = smoke_job.fetch('services').fetch('redis')

    assert_equal 'redis:7.4', redis.fetch('image'),
                 'the smoke job must run against the same redis:7.4 the release lane pins'
  end

  # --- diagnostics ---------------------------------------------------------

  # Every failure path must name the condition that went unmet. A shared
  # message ("smoke failed") sends the reader back to the log; a distinct one
  # per failure tells them what actually broke.
  def test_every_failure_path_emits_its_own_error_diagnostic
    diagnostics = error_diagnostics

    assert_operator diagnostics.size, :>=, 5,
                    'the smoke job has several independent failure paths; each needs its own `::error::` diagnostic'

    duplicates = diagnostics.tally.select { |_, count| count > 1 }.keys

    assert_empty duplicates,
                 'each failure path needs a DISTINCT `::error::` diagnostic; ' \
                 "these repeat: #{duplicates.inspect}"
  end

  # The specific conditions the smoke exists to catch. Each must have its own
  # diagnostic, so a regression that drops one is visible by name.
  def test_each_unmet_condition_has_a_named_diagnostic
    expected = {
      'the version is not published on RubyGems' => /not on RubyGems/,
      'the consumer app did not boot' => /did not boot/,
      'the engine mount did not serve /wurk' => /returned HTTP/,
      'the swarm never executed the job' => /marker absent/,
      'the demo endpoint did not respond' => /did not respond/,
      'the demo reports a different version' => /reports version/
    }
    text = executable_content

    expected.each do |condition, pattern|
      assert_match pattern, text, "no `::error::` diagnostic names the unmet condition: #{condition}"
    end
  end

  # --- no rollback ---------------------------------------------------------

  # The publish tail is irreversible by design (`gem push`), so the smoke is
  # post-publish evidence only. A compensation step here would be a lie about
  # a lane that cannot compensate — and would delete a published gem.
  #
  # Scanned over the executable content only (step names + `run:` bodies), so
  # the header comment that explains WHY there is no rollback does not trip
  # the check that there is no rollback.
  def test_contains_no_rollback_or_compensation_step
    forbidden = {
      'gem push' => /gem\s+push/,
      'gem delete' => /gem\s+(delete|uninstall|yank)/,
      'release delete' => /release\s+delete/,
      'revert' => /\brevert\b/,
      'rollback' => /\broll\s*back\b|\brollback\b/i
    }

    forbidden.each do |what, pattern|
      refute_match pattern, executable_content,
                   "release-smoke.yml must not contain a #{what} step — the publish tail is irreversible"
    end
  end

  # --- the consumer app boots in production mode ---------------------------

  # Rails reads SECRET_KEY_BASE in production; SECRET_KEY_BASE_DUMMY is only
  # Wurk's "this is a build step" marker (RailsBoot#building?) and is not a
  # secret. Every process that boots the throwaway app in production must
  # therefore get a real one.
  def test_every_production_boot_exports_a_real_secret_key_base
    booting_steps = consumer_app_steps

    refute_empty booting_steps, 'release-smoke.yml must boot the consumer app somehow'

    booting_steps.each do |step|
      run = step.fetch('run', '')
      label = "the step #{step['name'].inspect}"

      assert_match(/export\s+SECRET_KEY_BASE=/, run,
                   "#{label} boots the Rails app in production mode and must export a real SECRET_KEY_BASE")
      assert_match(/SecureRandom\.hex\(64\)/, run,
                   "#{label} must export a SECRET_KEY_BASE of at least 64 hex chars")
    end
  end

  # The dummy marker is not a substitute for the secret, and a step that
  # relies on it alone is the bug this pins: Rails in production wants the
  # real secret, and Wurk reads the dummy as "this is a build step".
  def test_no_step_relies_on_secret_key_base_dummy_alone
    offenders = smoke_job.fetch('steps').select { |step| step.fetch('run', '').include?('SECRET_KEY_BASE_DUMMY') }
    message = 'release-smoke.yml must not use SECRET_KEY_BASE_DUMMY — ' \
              "it is Wurk's build-step marker, not a production secret"

    assert_empty offenders.map { |step| step['name'] }, message
  end

  # WURK_DISABLED=1 silences the railtie's own swarm boot. The web process
  # and the one-off `rails runner` must not fork a swarm of their own; the
  # swarm process itself must NOT carry the flag, or it never runs a worker.
  def test_wurk_disabled_is_set_only_where_a_swarm_must_not_fork
    disabled_lines = executable_content.lines.grep(/WURK_DISABLED=1/).map(&:strip)

    refute_empty disabled_lines, 'the web process must carry WURK_DISABLED=1 so it does not fork a swarm'

    disabled_lines.each do |line|
      refute_match(/wurkswarm/, line,
                   'the wurkswarm process must NOT carry WURK_DISABLED=1 — it is the swarm, ' \
                   'and the flag would silence it')
    end
  end

  # --- release.yml's caller job -------------------------------------------

  def test_release_yml_calls_the_smoke_workflow_from_a_smoke_job
    job = release_workflow.fetch('jobs').fetch('smoke')

    assert_equal %w[preflight release demo], job.fetch('needs'),
                 'the `smoke` job must need [preflight, release, demo] so it runs after the publish and the deploy'
    assert_equal './.github/workflows/release-smoke.yml', job.fetch('uses')
    assert_equal '${{ needs.preflight.outputs.version }}', job.dig('with', 'version')
  end

  # Least privilege: the smoke caller only curls RubyGems and the live demo.
  # It must not inherit the workflow-level `id-token: write` — that
  # permission is what the RubyGems trusted-publishing exchange needs.
  def test_smoke_caller_job_holds_no_id_token_write
    permissions = release_workflow.fetch('jobs').fetch('smoke').fetch('permissions', {})

    refute_includes permissions.keys, 'id-token',
                    'the `smoke` job must not hold id-token — it only curls RubyGems and the demo'
    assert_equal({ 'contents' => 'read' }, permissions,
                 'the `smoke` job must ask for exactly `contents: read`')
  end

  # The release lane must never cancel a run that is publishing: a cancelled
  # release leaves a version half-published with no tag behind it.
  def test_release_workflow_keeps_concurrency_cancel_in_progress_false
    concurrency = release_workflow.fetch('concurrency')

    assert_equal 'release', concurrency.fetch('group')
    refute concurrency.fetch('cancel-in-progress'),
           'the release lane must never cancel in progress — a cancelled publish leaves a burned version'
  end

  # --- helpers -------------------------------------------------------------

  private

  # YAML 1.1 reads a bare `on:` key as the boolean `true`, so the trigger
  # block is under that key, not under "on".
  def smoke_triggers
    triggers = smoke_workflow[true] || smoke_workflow['on']

    raise 'release-smoke.yml has no `on:` block' if triggers.nil?

    triggers
  end

  def smoke_workflow
    @smoke_workflow ||= YAML.load_file(SMOKE_YML)
  end

  def smoke_job
    smoke_workflow.fetch('jobs').fetch('smoke')
  end

  def release_workflow
    @release_workflow ||= YAML.load_file(RELEASE_YML)
  end

  # The steps that boot the throwaway Rails app in production mode: the ones
  # that run a `bin/rails` / `bundle exec rails` / `wurkswarm` command.
  def consumer_app_steps
    smoke_job.fetch('steps').select do |step|
      run = step.fetch('run', '')

      run.match?(%r{bin/rails|bundle exec rails|bundle exec wurkswarm})
    end
  end

  # Every `::error::` message the workflow can emit, in file order.
  def error_diagnostics
    executable_content.scan(/::error::(.+?)"/).flatten.map(&:strip)
  end

  # The workflow's executable content: every step's `run:` body plus its
  # name. YAML comments are prose about the workflow, not the workflow —
  # the header explains that there is no rollback, which must not read as
  # a rollback step.
  def executable_content
    smoke_job.fetch('steps').map { |step| "#{step['name']}\n#{step.fetch('run', '')}" }.join("\n")
  end
end
