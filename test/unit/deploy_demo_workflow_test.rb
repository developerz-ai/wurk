# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# Gates the contract of .github/workflows/deploy-demo.yml — the workflow that
# ships the public demo (wurk.demo.developerz.ai).
#
# The demo deploy is INDIRECT: CI pushes an image, and infra's ArgoCD Image
# Updater syncs the newest digest. Nothing in CI observes the result, so a
# demo can sit on a stale digest for weeks with every run green — that is
# exactly how it went stale across several releases. This workflow closes that
# hole by recording the deploy as a GitHub Deployment object and then WAITING,
# in a bounded loop, for the demo to report the new version.
#
# The test pins the parts that make that evidence real:
#
#   * the `build` job holds exactly `contents: read` + `deployments: write` —
#     the Deployment object needs the second, and nothing else is needed;
#   * a Deployment is created for environment `demo` at the BUILT commit
#     (steps.built.outputs.sha), so `gh api repos/{owner}/{repo}/deployments`
#     lists a deployment for `demo` at that commit;
#   * the demo version probe is BOUNDED, compares /wurk/api/meta's `version`
#     against the version bundled by the built demo image, and its two exits
#     set the deployment status to `success` / `failure` respectively — with
#     the timeout exit failing the job;
#   * the `authorize` job's DEMO_DEPLOYERS allowlist and its `trusted` waiver
#     are UNCHANGED — they are the door this workflow hangs, and a silent
#     loosening of them would not be caught by any other test here.
#
# Reads files; touches no Redis, no network and no shared state.
class DeployDemoWorkflowTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  DEPLOY_YML = File.join(ROOT, '.github', 'workflows', 'deploy-demo.yml')
  RELEASE_YML = File.join(ROOT, '.github', 'workflows', 'release.yml')

  # --- permissions ---------------------------------------------------------

  # The build job records a Deployment, so it needs `deployments: write`. It
  # pushes no code, opens no PR and holds no OIDC token, so it must ask for
  # NOTHING else: a wider set is a widening of the blast radius of a job that
  # runs on every push to main.
  def test_build_job_holds_exactly_contents_read_and_deployments_write
    permissions = build_job.fetch('permissions')

    assert_equal({ 'contents' => 'read', 'deployments' => 'write' }, permissions,
                 'the `build` job must ask for exactly `contents: read` + `deployments: write`')
  end

  # Least privilege at the workflow level too: the workflow-level block is the
  # ceiling every job without its own `permissions:` inherits, so `id-token:
  # write` or `actions: write` there would leak to `authorize` as well.
  def test_workflow_level_permissions_stay_contents_read
    assert_equal({ 'contents' => 'read' }, deploy_workflow.fetch('permissions'),
                 'the workflow-level permissions must stay `contents: read`')
  end

  # The `authorize` job gates the door this workflow hangs on. It needs no
  # write permission of any kind, so it must not inherit one.
  def test_authorize_job_holds_no_write_permission
    permissions = authorize_job.fetch('permissions', { 'contents' => 'read' })

    assert_equal({ 'contents' => 'read' }, permissions,
                 'the `authorize` job must hold `contents: read` and nothing else')
  end

  # --- the Deployment record ----------------------------------------------

  # The whole point of the new step: a Deployment object for environment
  # `demo`, whose ref is the BUILT commit — not `github.sha` (the SHA of the
  # ref the WORKFLOW was loaded from, which differs whenever `inputs.ref`
  # points elsewhere).
  def test_a_deployment_is_created_for_the_demo_environment_at_the_built_commit
    step = deployment_step

    run = step.fetch('run')

    assert_match(%r{gh api --method POST "repos/\$\{GITHUB_REPOSITORY\}/deployments"}, run,
                 'the workflow must create a Deployment through the deployments API')
    assert_match(/-f\s+environment=demo\b/, run,
                 'the Deployment must target the `demo` environment')
    assert_match(/-f\s+ref="\$\{SHA\}"/, run,
                 'the Deployment ref must be the built commit SHA')
    assert_equal '${{ steps.built.outputs.sha }}', step.dig('env', 'SHA'),
                 'the Deployment ref must come from steps.built.outputs.sha'
  end

  # `gh api` needs a token. The workflow's own token is the only one that can
  # write deployments here, and it must be passed through the environment (not
  # interpolated into the command line, where it would land in the log).
  def test_the_deployment_steps_authenticate_with_the_workflow_token
    ['create deployment', 'mark deployment in progress', 'wait for the demo to report the new version']
      .each do |name|
      step = build_job.fetch('steps').find { |candidate| candidate['name'] == name }

      refute_nil step, "the build job lost its #{name.inspect} step"

      assert_equal '${{ github.token }}', step.dig('env', 'GH_TOKEN'),
                   "the #{name.inspect} step must authenticate with the workflow token"
    end
  end

  # The deployment id is needed by every status call, so it has to travel from
  # the creating step to the ones that set the status.
  def test_the_deployment_id_is_carried_between_the_steps
    create = deployment_step

    assert_equal 'deployment', create['id'],
                 'the Deployment-creating step must have an id so its output can be referenced'
    assert_match(/echo "id=\$\{deployment_id\}" >> "\$GITHUB_OUTPUT"/, create.fetch('run'),
                 'the creating step must publish the Deployment id as a step output')
    in_progress = build_job.fetch('steps').find { |s| s['name'] == 'mark deployment in progress' }

    assert_equal '${{ steps.deployment.outputs.id }}', in_progress.dig('env', 'DEPLOYMENT_ID'),
                 'the status steps must address the Deployment by the id the creating step published'
  end

  # --- the bounded version probe ------------------------------------------

  # The probe compares the version the demo SERVES against the version the
  # built image bundles. The served version is the GEM version
  # (::Wurk::VERSION), not a commit SHA, which the demo does not report.
  def test_the_probe_compares_the_demo_version_against_the_built_images_bundled_version
    step = probe_step
    run = step.fetch('run')

    assert_match(%r{curl -fsS https://wurk\.demo\.developerz\.ai/wurk/api/meta}, run,
                 'the probe must read the demo version from /wurk/api/meta')
    assert_match(/\["version"\]/, run,
                 'the probe must read the `version` field of /wurk/api/meta')
    assert_equal '${{ steps.demo_version.outputs.version }}', step.dig('env', 'VERSION'),
                 'the probe must compare against the resolved version bundled by the built image'
  end

  # The version the probe compares against must be the version the built demo
  # image actually bundles. The image installs demo/Gemfile.lock frozen, so
  # that lock's path-sourced `wurk (...)` entry is the source of truth — not
  # the checkout's lib/wurk/version.rb, which can differ on an ordinary push
  # without a version bump and would make the probe impossible to satisfy.
  def test_the_expected_version_comes_from_the_demo_bundle_lock
    step = build_job.fetch('steps').find { |candidate| candidate['name'] == 'resolve demo version' }

    refute_nil step, 'the build job must resolve the demo version it expects'

    run = step.fetch('run')

    assert_match(%r{demo/Gemfile\.lock}, run,
                 'the expected version must come from the demo bundle lock the image installs')
    assert_match(/wurk \\\(.*\\\)\$/, run,
                 'the expected version must be the lock\'s path-sourced wurk version')
    assert_match(/\^    wurk /, run,
                 'the lock entry read must be the path-sourced wurk spec')
    refute_match(%r{lib/wurk/version\.rb|require "wurk/version"}, run,
                 'the expected version must not come from the checkout\'s version file')
  end

  # The expected version must be read from the checkout of the commit being
  # deployed — the same commit the Deployment is created at. `inputs.ref` can
  # point anywhere, so the checkout step pins the demo bundle lock to the
  # built commit.
  def test_the_checkout_is_the_commit_the_deployment_is_created_at
    checkout = build_job.fetch('steps').find { |candidate| candidate['uses'].to_s.start_with?('actions/checkout') }

    refute_nil checkout, 'the build job must check out the commit it deploys'

    assert_equal '${{ inputs.ref }}', checkout.dig('with', 'ref'),
                 'the checkout must be the ref being deployed, so the demo bundle lock is that commit\'s'
  end

  # The wait MUST be bounded: an unbounded loop would hang the job until the
  # job timeout killed it, with no Deployment status recorded — the run would
  # go red with nothing to show for it.
  def test_the_version_probe_is_bounded
    run = probe_step.fetch('run')

    assert_match(/for\s+\w+\s+in\s+\$\(seq 1 \d+\)/, run,
                 'the probe loop must have an explicit upper bound on its iterations')
    assert_match(/sleep \d+/, run,
                 'the probe must wait between attempts rather than busy-looping')
  end

  # The bound has to fit inside the job's own timeout: the build and push
  # happen first, so a probe window that cannot fit would make every run fail
  # on timeout rather than on a real mismatch.
  def test_the_probe_window_fits_inside_the_job_timeout
    run = probe_step.fetch('run')

    attempts = run[/for\s+\w+\s+in\s+\$\(seq 1 (\d+)\)/, 1].to_i
    sleep_seconds = run[/sleep (\d+)/, 1].to_i

    assert_operator attempts, :>, 0, 'the probe must allow at least one attempt'
    assert_operator sleep_seconds, :>, 0, 'the probe must sleep between attempts'

    window_minutes = (attempts * sleep_seconds) / 60.0
    timeout_minutes = build_job.fetch('timeout-minutes')

    assert_operator window_minutes, :<, timeout_minutes,
                    "the probe window (#{window_minutes.round(1)} min) must fit inside the " \
                    "job timeout (#{timeout_minutes} min)"
  end

  # A rollout can answer /wurk/api/meta with HTML or an empty body for a
  # moment. A JSON parse error must read as "no version yet" and let the
  # probe RETRY — not abort the step, which would fail the run on a
  # transient blip and record no failure status.
  def test_a_non_json_body_does_not_abort_the_probe
    run = probe_step.fetch('run')

    assert_match(/rescue StandardError/, run,
                 'the version parse must tolerate a body that is not JSON')
    assert_match(/\| *true\)/, run,
                 'the version parse must not abort the step on a parse error')
  end

  # --- the two exits of the probe ------------------------------------------

  # Match on: version seen → status success → job continues.
  def test_a_matching_version_sets_the_deployment_status_to_success
    run = probe_step.fetch('run')

    success = run[/if \[ -n "\$matched" \]; then(.*?)fi/m, 1]

    refute_nil success, 'the probe must have a success branch'

    assert_match(%r{deployments/\$\{DEPLOYMENT_ID\}/statuses}, success,
                 'the success branch must post a Deployment status')
    assert_match(/-f\s+state=success\b/, success,
                 'the success branch must set the Deployment status to success')
    assert_match(/exit 0/, success,
                 'the success branch must leave the step (and the job) successful')
  end

  # Match on: bound exhausted → status failure → job fails, with the last
  # version seen printed so the reader knows what the demo was serving.
  def test_a_timeout_sets_the_deployment_status_to_failure_and_fails_the_job
    run = probe_step.fetch('run')

    failure = run[/\n\s*if \[ -n "\$matched" \]; then.*?fi\n(.*)\z/m, 1]

    refute_nil failure, 'the probe must have a failure branch after the success one'

    assert_match(%r{deployments/\$\{DEPLOYMENT_ID\}/statuses}, failure,
                 'the failure branch must post a Deployment status')
    assert_match(/-f\s+state=failure\b/, failure,
                 'the failure branch must set the Deployment status to failure')
    assert_match(/exit 1/, failure,
                 'the failure branch must fail the job')
  end

  # The log has to say what the demo was actually serving: "it did not match"
  # is useless without the version that was seen.
  def test_the_timeout_path_prints_the_last_version_seen
    run = probe_step.fetch('run')

    assert_match(/last_version/, run,
                 'the probe must keep the last version it saw')
    assert_match(/::error::[^\n]*\$\{last_version\}/, run,
                 'the failure diagnostic must name the last version the demo reported')
  end

  # The success and failure statuses are two branches of one probe; a
  # regression that made both set `success` would leave the Deployment green
  # on a demo that never updated.
  def test_the_two_statuses_are_distinct
    states = probe_step.fetch('run').scan(/-f\s+state=(\w+)/).flatten

    assert_includes states, 'success', 'the probe must set a `success` status'
    assert_includes states, 'failure', 'the probe must set a `failure` status'
  end

  # --- the authorize door is unchanged --------------------------------------

  # The allowlist is the only thing between a write-access user and a
  # hand-dispatched deploy of an arbitrary ref. It must keep reading
  # DEMO_DEPLOYERS and rejecting an unlisted actor.
  def test_the_authorize_job_keeps_the_demo_deployers_allowlist
    run = authorize_run

    assert_equal '${{ vars.DEMO_DEPLOYERS }}', authorize_job.dig('steps', 0, 'env', 'ALLOW'),
                 'the authorize job must read the DEMO_DEPLOYERS repo variable'
    assert_match(/grep -qx "\$ACTOR"/, run,
                 'the authorize job must still match the actor against the allowlist')
    assert_match(/::error::\$ACTOR is not in DEMO_DEPLOYERS\./, run,
                 'the authorize job must still reject an unlisted actor')
  end

  # The `trusted` waiver is pinned to the one caller it is meant for: the
  # release workflow, on main. A waiver honoured from anywhere would let any
  # caller skip the allowlist.
  def test_the_trusted_waiver_is_still_pinned_to_the_release_workflow_on_main
    run = authorize_run

    assert_match(/if \[ "\$TRUSTED" = "true" \]; then/, run,
                 'the authorize job must still honour the `trusted` input')
    assert_match(/\[ "\$CALLER" = "release" \]/, run,
                 'the `trusted` waiver must be pinned to the release workflow')
    assert_match(%r{\[ "\$GITHUB_REF" = "refs/heads/main" \]}, run,
                 'the `trusted` waiver must be pinned to main')
    assert_match(/::error::trusted:true is only honoured from the release workflow on main/, run,
                 'the unauthorized `trusted` path must still fail loudly')
  end

  # release.yml calls this workflow with `ref` and `trusted: true`. If that
  # call shape changed, the release lane would stop shipping the released tag
  # to the demo.
  def test_release_yml_still_calls_the_deploy_workflow_with_ref_and_trusted
    demo = release_workflow.fetch('jobs').fetch('demo')

    assert_equal './.github/workflows/deploy-demo.yml', demo.fetch('uses')
    assert demo.dig('with', 'trusted'),
           'release.yml must still pass `trusted: true` — the allowlist waiver'
    assert_includes demo.dig('with', 'ref').to_s, 'preflight.outputs.tag',
                    'release.yml must still pass the released tag as `ref`'
  end

  # --- helpers -------------------------------------------------------------

  private

  def deploy_workflow
    @deploy_workflow ||= YAML.load_file(DEPLOY_YML)
  end

  def release_workflow
    @release_workflow ||= YAML.load_file(RELEASE_YML)
  end

  def build_job
    deploy_workflow.fetch('jobs').fetch('build')
  end

  def authorize_job
    deploy_workflow.fetch('jobs').fetch('authorize')
  end

  def build_step(name)
    step = build_job.fetch('steps').find { |candidate| candidate['name'] == name }

    raise "deploy-demo.yml lost its #{name.inspect} step" if step.nil?

    step
  end

  def deployment_step
    build_step('create deployment')
  end

  def probe_step
    build_step('wait for the demo to report the new version')
  end

  def authorize_run
    authorize_job.fetch('steps').map { |step| step.fetch('run', '') }.join("\n")
  end
end
