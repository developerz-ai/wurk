# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'json'
require 'fileutils'
require 'open3'
require 'tmpdir'

# Gates the contract of .github/workflows/deploy-demo.yml — the workflow that
# ships the public demo (wurk.demo.developerz.ai).
#
# The demo deploy is INDIRECT: CI pushes an image, and infra's ArgoCD Image
# Updater syncs the newest digest. Nothing in CI observes the result, so a
# demo can sit on a stale digest for weeks with every run green — that is
# exactly how it went stale across several releases. This workflow closes that
# hole by recording the deploy as a GitHub Deployment object and then WAITING,
# in a bounded loop, for the demo to report the built commit.
#
# The test pins the parts that make that evidence real:
#
#   * the `build` job holds exactly `contents: read` + `deployments: write` —
#     the Deployment object needs the second, and nothing else is needed;
#   * a Deployment is created for environment `demo` at the BUILT commit
#     (steps.built.outputs.sha), so `gh api repos/{owner}/{repo}/deployments`
#     lists a deployment for `demo` at that commit;
#   * the commit probe is BOUNDED, compares /demo/build's `sha` against the
#     commit it built (the image carries that commit as a build arg), and its
#     two exits set the deployment status to `success` / `failure` respectively
#     — with the timeout exit failing the job;
#   * the probe is also EXECUTED with stubbed curl/gh/sleep on PATH: a commit
#     that never matches must exhaust every retry, post `failure` and exit
#     nonzero, a matching one must post `success` and exit 0. Reading the
#     script's shape alone cannot catch the comparison turning always-true,
#     which would mark a frozen rollout successful;
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

  NEW_SHA = 'a' * 40
  OLD_SHA = 'b' * 40

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
    assert_equal '${{ steps.built.outputs.sha }}', step.dig('env', 'SHA'),
                 'the Deployment ref must come from steps.built.outputs.sha'
  end

  # The step EXECUTED with a stubbed `gh`: the request body it sends is the
  # contract. `required_contexts` must be an explicit empty array — omitted,
  # the API defaults it to every status context on the ref and answers 409
  # "Commit status checks failed" while CI is still running or anything is
  # red, which failed every push to main from 2026-10-23. This workflow is
  # itself the gate on the demo serving, so it waits on no other context.
  def test_executed_create_step_sends_an_empty_required_contexts_and_records_the_id
    result = run_create_deployment(sha: 'abc1234def')

    assert_predicate result[:status], :success?, "create deployment failed: #{result[:stderr]}"
    assert_includes result[:gh_argv], 'repos/developerz-ai/wurk/deployments'
    assert_equal({ 'ref' => 'abc1234def', 'environment' => 'demo', 'auto_merge' => false,
                   'required_contexts' => [] }, JSON.parse(result[:gh_stdin]),
                 'the Deployment body must target `demo` at the built SHA with no required contexts')
    assert_equal "id=7\n", result[:github_output], 'the step must record the created Deployment id'
  end

  # `gh api` needs a token. The workflow's own token is the only one that can
  # write deployments here, and it must be passed through the environment (not
  # interpolated into the command line, where it would land in the log).
  def test_the_deployment_steps_authenticate_with_the_workflow_token
    ['create deployment', 'mark deployment in progress', 'wait for the demo to serve the built commit']
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

  # --- the bounded commit probe -------------------------------------------

  # The probe compares the commit the demo SERVES against the commit this run
  # built. A gem version would not do: on a push without a version bump the old
  # pods already report it, so a frozen Image Updater passed on attempt 1.
  def test_the_probe_compares_the_served_commit_against_the_built_commit
    step = probe_step
    run = step.fetch('run')

    assert_match(%r{curl [^\n]*https://wurk\.demo\.developerz\.ai/demo/build}, run,
                 'the probe must read the served commit from /demo/build')
    assert_match(/\["sha"\]/, run, 'the probe must read the `sha` field of /demo/build')
    refute_match(%r{curl [^\n]*api/meta|\["version"\]}, run, 'the probe must not fall back to the gem version')
    assert_equal '${{ steps.built.outputs.sha }}', step.dig('env', 'EXPECTED_SHA'),
                 'the probe must compare against the commit this run built'
  end

  # The chain that makes the comparison real: the build passes the commit, the
  # image bakes it in, the demo answers with it.
  def test_the_image_carries_the_built_commit_to_the_demo_route
    push = build_job.fetch('steps').find { |step| step['uses'].to_s.start_with?('docker/build-push-action') }

    assert_includes push.dig('with', 'build-args').to_s, 'WURK_DEMO_BUILD_SHA=${{ steps.built.outputs.sha }}'

    dockerfile = File.read(File.join(ROOT, 'Dockerfile'))

    assert_match(/^ARG WURK_DEMO_BUILD_SHA/, dockerfile)
    assert_match(/^ENV WURK_DEMO_BUILD_SHA=\$WURK_DEMO_BUILD_SHA$/, dockerfile)

    routes = File.read(File.join(ROOT, 'demo', 'config', 'routes.rb'))

    assert_match(%r{get "/demo/build"}, routes)
    assert_includes routes, 'ENV.fetch("WURK_DEMO_BUILD_SHA"'
  end

  # Demo-only: the gem's own payload must not grow a build field.
  def test_the_build_sha_stays_out_of_the_gem
    sources = Dir[File.join(ROOT, '{app,lib}', '**', '*.rb')]
    leaks = sources.select { |path| File.read(path).include?('WURK_DEMO_BUILD_SHA') }

    assert_empty leaks, 'WURK_DEMO_BUILD_SHA belongs to the demo app, not the shipped gem'
  end

  # `inputs.ref` can point anywhere, so the checkout pins what gets built, and
  # steps.built resolves the commit from that checkout.
  def test_the_checkout_is_the_commit_the_deployment_is_created_at
    checkout = build_job.fetch('steps').find { |candidate| candidate['uses'].to_s.start_with?('actions/checkout') }

    refute_nil checkout, 'the build job must check out the commit it deploys'

    assert_equal '${{ inputs.ref }}', checkout.dig('with', 'ref'),
                 'the checkout must be the ref being deployed'
  end

  # The wait MUST be bounded: an unbounded loop would hang the job until the
  # job timeout killed it, with no Deployment status recorded — the run would
  # go red with nothing to show for it.
  def test_the_commit_probe_is_bounded
    run = probe_step.fetch('run')

    assert_match(/for\s+\w+\s+in\s+\$\(seq 1 \d+\)/, run,
                 'the probe loop must have an explicit upper bound on its iterations')
    assert_match(/sleep \d+/, run,
                 'the probe must wait between attempts rather than busy-looping')
  end

  # A demo that accepts the TCP connection but stalls the response must not
  # block curl until the JOB timeout killed the step: the probe runs after
  # `mark deployment in progress`, so a hang there leaves the Deployment
  # in_progress with no failure status and no last-commit diagnostic. Each
  # request is therefore bounded twice — handshake and total — and the
  # budget test below charges the total to the probe's window.
  def test_the_probe_curl_requests_carry_connection_and_total_deadlines
    curl_line = probe_step.fetch('run')[/curl [^\n]+/]

    refute_nil curl_line, 'the probe must fetch /demo/build with curl'

    connect_seconds = curl_line[/--connect-timeout (\d+)/, 1].to_i
    request_seconds = curl_line[/--max-time (\d+)/, 1].to_i

    assert_operator connect_seconds, :>, 0, 'curl must bound the TCP connection'
    assert_operator request_seconds, :>, 0, 'curl must bound the whole request'
    assert_operator connect_seconds, :<, request_seconds,
                    'the connection deadline must sit inside the total request deadline'
  end

  # The bound has to fit inside the job's own timeout: the build and push
  # happen first, so a probe window that cannot fit would make every run fail
  # on timeout rather than on a real mismatch. A stalled request burns its
  # --max-time before the sleep, so the request deadline is part of the
  # per-attempt cost and of the window.
  def test_the_probe_window_fits_inside_the_job_timeout
    run = probe_step.fetch('run')

    attempts = run[/for\s+\w+\s+in\s+\$\(seq 1 (\d+)\)/, 1].to_i
    sleep_seconds = run[/sleep (\d+)/, 1].to_i
    request_seconds = run[/--max-time (\d+)/, 1].to_i

    assert_operator attempts, :>, 0, 'the probe must allow at least one attempt'
    assert_operator sleep_seconds, :>, 0, 'the probe must sleep between attempts'
    assert_operator request_seconds, :>, 0, 'the probe must bound each request in time'

    window_minutes = (attempts * (sleep_seconds + request_seconds)) / 60.0
    timeout_minutes = build_job.fetch('timeout-minutes')

    # Half, not merely less than: the image build and push run in the same
    # job before the probe, so the window must leave real room for them.
    assert_operator window_minutes, :<=, timeout_minutes / 2.0,
                    "the probe's worst-case window (#{window_minutes.round(1)} min) must leave " \
                    "room for the image build and push inside the job timeout (#{timeout_minutes} min)"
  end

  # A rollout can answer /demo/build with a 404, HTML or an empty body for a
  # moment. A JSON parse error must read as "no commit yet" and let the
  # probe RETRY — not abort the step, which would fail the run on a
  # transient blip and record no failure status.
  def test_a_non_json_body_does_not_abort_the_probe
    run = probe_step.fetch('run')

    assert_match(/rescue StandardError/, run,
                 'the parse must tolerate a body that is not JSON')
    assert_match(/\| *true\)/, run,
                 'the parse must not abort the step on a parse error')
  end

  # --- the two exits of the probe ------------------------------------------

  # Match on: commit seen → status success → job continues.
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
  # commit seen printed so the reader knows what the demo was serving.
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
  # is useless without the commit that was seen.
  def test_the_timeout_path_prints_the_last_commit_seen
    run = probe_step.fetch('run')

    assert_match(/last_sha/, run, 'the probe must keep the last commit it saw')
    assert_match(/::error::[^\n]*\$\{last_sha\}/, run,
                 'the failure diagnostic must name the last commit the demo reported')
  end

  # The success and failure statuses are two branches of one probe; a
  # regression that made both set `success` would leave the Deployment green
  # on a demo that never updated.
  def test_the_two_statuses_are_distinct
    states = probe_step.fetch('run').scan(/-f\s+state=(\w+)/).flatten

    assert_includes states, 'success', 'the probe must set a `success` status'
    assert_includes states, 'failure', 'the probe must set a `failure` status'
  end

  # --- the probe executed, not just read ------------------------------------

  # The shape tests above pass even if the commit comparison is replaced by
  # an always-true condition — the exact regression that would mark a stale
  # demo successful. These tests EXECUTE the step's run block with stubbed
  # curl/gh/sleep first on PATH and assert the probe's actual behaviour at
  # both exits.

  # The demo never reports the built commit: every retry must run, the
  # Deployment must be marked failure (never success), the step must exit
  # nonzero, and the log must say what the demo was serving.
  def test_executed_probe_exhausts_retries_posts_failure_and_exits_nonzero_on_a_frozen_rollout
    result = run_probe(expected_sha: NEW_SHA, served_sha: OLD_SHA)

    assert_equal probe_loop_bound, result[:curl_calls].length,
                 'a commit that never matches must exhaust every retry, not give up early'

    status_calls = result[:gh_calls].grep(%r{deployments/.*/statuses})

    assert_equal 1, status_calls.length, 'exactly one terminal status must be posted'
    assert_includes status_calls.first, 'state=failure'
    refute_includes result[:gh_calls].join("\n"), 'state=success',
                    'a stale demo must never be marked successful'

    refute_predicate result[:status], :success?, 'the probe must exit nonzero'
    assert_equal 1, result[:status].exitstatus
    assert_includes result[:stdout], OLD_SHA,
                    'the diagnostic must name the last commit the demo served'
  end

  def test_executed_probe_posts_success_and_exits_zero_on_a_matching_commit
    result = run_probe(expected_sha: NEW_SHA, served_sha: NEW_SHA)

    assert_equal 1, result[:curl_calls].length,
                 'a first-attempt match must not poll again'
    assert_includes result[:gh_calls].join("\n"), 'state=success'
    refute_includes result[:gh_calls].join("\n"), 'state=failure'

    assert result[:status].success? || false
    assert_predicate result[:status], :success?, 'a matching commit must leave the step (and job) green'
  end

  # A mismatch on attempt N is the normal rollout state — Image Updater has
  # not synced yet. The probe must keep polling until the version matches,
  # not fail on the first stale answer.
  def test_executed_probe_keeps_polling_until_the_demo_reports_the_built_commit
    result = run_probe(expected_sha: NEW_SHA, served_sha: OLD_SHA, match_after: 5)

    assert_equal 5, result[:curl_calls].length
    assert_predicate result[:status], :success?
    assert_includes result[:gh_calls].join("\n"), 'state=success'
  end

  # Executed companion to test_a_non_json_body_does_not_abort_the_probe: a
  # HTML/empty body reads as "no commit yet" and the loop retries until a
  # real JSON commit shows up.
  def test_executed_probe_retries_a_non_json_body_until_the_demo_reports_the_commit
    result = run_probe(expected_sha: NEW_SHA, served_sha: NEW_SHA,
                       served_body: '<html>rolling</html>', match_after: 3)

    assert_equal 3, result[:curl_calls].length
    assert_predicate result[:status], :success?
    assert_includes result[:gh_calls].join("\n"), 'state=success'
  end

  # A later deploy can overtake the release's own: a cached rebuild of the older
  # commit keeps its digest and `created`, so Image Updater stays on the newer one.
  def test_executed_probe_accepts_a_descendant_github_confirms
    result = run_probe(expected_sha: NEW_SHA, served_sha: OLD_SHA, compare: 'ahead')

    assert_predicate result[:status], :success?
    assert_equal 1, result[:curl_calls].length
    assert_includes result[:gh_calls].join("\n"), "compare/#{NEW_SHA}...#{OLD_SHA}"
    assert_includes result[:gh_calls].join("\n"), 'state=success'
  end

  def test_executed_probe_does_not_accept_a_commit_that_is_behind_or_diverged
    %w[behind diverged identical].each do |relation|
      result = run_probe(expected_sha: NEW_SHA, served_sha: OLD_SHA, compare: relation)

      refute_predicate result[:status], :success?, "#{relation} must not pass"
      refute_includes result[:gh_calls].join("\n"), 'state=success'
    end
  end

  # An API blip must never read as success, and must not end the wait either.
  def test_executed_probe_fails_closed_and_says_so_when_the_compare_errors
    result = run_probe(expected_sha: NEW_SHA, served_sha: OLD_SHA, compare: 'error')

    refute_predicate result[:status], :success?
    assert_equal probe_loop_bound, result[:curl_calls].length, 'a failed compare must keep polling'
    refute_includes result[:gh_calls].join("\n"), 'state=success'
    assert_includes result[:stdout], 'compare'
    assert_includes result[:stdout], 'could not be proved'
  end

  def test_executed_probe_retries_a_compare_blip_and_then_passes
    result = run_probe(expected_sha: NEW_SHA, served_sha: OLD_SHA, compare: 'error-then-ahead')

    assert_predicate result[:status], :success?
    assert_equal 2, result[:curl_calls].length
  end

  # A hand dispatch wants exactly its commit: crediting the image it is replacing
  # would pass a rollback instantly.
  def test_executed_probe_gives_a_hand_dispatch_no_credit_for_a_newer_commit
    result = run_probe(expected_sha: NEW_SHA, served_sha: OLD_SHA, compare: 'ahead', allow_newer: 'false')

    refute_predicate result[:status], :success?
    refute_includes result[:gh_calls].join("\n"), 'compare/'
  end

  def test_executed_probe_says_the_gem_and_tag_are_live_when_a_release_call_fails
    result = run_probe(expected_sha: NEW_SHA, served_sha: OLD_SHA, trusted: 'true')

    refute_predicate result[:status], :success?
    assert_includes result[:stdout], 'the gem and tag are live'

    plain = run_probe(expected_sha: NEW_SHA, served_sha: OLD_SHA)

    refute_includes plain[:stdout], 'the gem and tag are live'
  end

  def test_executed_probe_does_not_block_a_rollback_it_cannot_verify
    result = run_probe(expected_sha: NEW_SHA, served_sha: OLD_SHA, has_route: 'false')

    assert_predicate result[:status], :success?
    assert_empty result[:curl_calls]
    assert_includes result[:stdout], '::warning::'
    assert_includes result[:gh_calls].join("\n"), 'unverified'
  end

  def test_a_push_never_rolls_the_demo_back
    steps = build_job.fetch('steps')
    push = steps.find { |step| step['uses'].to_s.start_with?('docker/build-push-action') }
    check = build_step('skip the push if the demo already serves a newer commit')

    assert_equal "steps.overtaken.outputs.skip != 'true'", push['if']
    assert_equal "steps.overtaken.outputs.skip != 'true'", build_step('verify pushed tags resolve')['if']
    assert_equal "${{ github.event_name != 'workflow_dispatch' || inputs.trusted == true }}",
                 check.dig('env', 'ALLOW_NEWER')
    assert_operator steps.index(check), :<, steps.index(push)
  end

  def test_executed_overtaken_check_skips_only_for_a_confirmed_descendant
    assert_equal 'skip=true', run_overtaken(compare: 'ahead')
    assert_equal 'skip=false', run_overtaken(compare: 'behind')
    assert_equal 'skip=false', run_overtaken(compare: 'error'), 'a failed read must build as usual'
    assert_equal 'skip=false', run_overtaken(compare: 'ahead', allow_newer: 'false'), 'a dispatch may roll back'
  end

  # .github/ is dockerignored: a build from this file alone differs only in the ENV
  # layer, with an identical `created`, and Image Updater breaks that tie by tag name.
  def test_editing_this_workflow_does_not_trigger_a_build
    paths = deploy_workflow.fetch(true).dig('push', 'paths')

    refute_includes paths, '.github/workflows/deploy-demo.yml'
    assert_includes File.read(File.join(ROOT, '.dockerignore')), '.github'
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
    build_step('wait for the demo to serve the built commit')
  end

  def probe_loop_bound
    probe_step.fetch('run')[/for\s+\w+\s+in\s+\$\(seq 1 (\d+)\)/, 1].to_i
  end

  # Runs the probe step's run block with `curl`, `gh` and `sleep` stubbed
  # onto PATH: curl serves the scripted answer and counts its calls, gh logs
  # every invocation, sleep is a no-op so a full retry bound costs nothing —
  # the retry COUNT is asserted, not its pace.
  def run_probe(expected_sha:, served_sha:, served_body: nil, match_after: nil, **options)
    Dir.mktmpdir('deploy-demo-probe') do |dir|
      stub_dir = File.join(dir, 'bin')
      state_dir = File.join(dir, 'state')
      Dir.mkdir(stub_dir)
      Dir.mkdir(state_dir)
      write_probe_stubs(stub_dir)

      script_path = File.join(dir, 'probe.sh')
      File.write(script_path, probe_step.fetch('run'))

      env = probe_env(
        stub_dir, state_dir,
        expected_sha: expected_sha,
        served_sha: served_sha,
        served_body: served_body,
        match_after: match_after,
        **options
      )
      stdout, stderr, status = Open3.capture3(env, 'bash', script_path)

      {
        status: status,
        stdout: stdout,
        stderr: stderr,
        curl_calls: read_stub_lines(File.join(state_dir, 'curl_calls')),
        gh_calls: read_stub_lines(File.join(state_dir, 'gh_calls'))
      }
    end
  end

  def run_overtaken(compare:, allow_newer: 'true')
    Dir.mktmpdir('deploy-demo-overtaken') do |dir|
      stub_dir = File.join(dir, 'bin')
      Dir.mkdir(stub_dir)
      write_probe_stubs(stub_dir)
      output = File.join(dir, 'output')
      env = probe_env(stub_dir, dir, expected_sha: NEW_SHA, served_sha: OLD_SHA, served_body: nil, match_after: nil,
                                     compare: compare, allow_newer: allow_newer).merge('GITHUB_OUTPUT' => output)
      run = build_step('skip the push if the demo already serves a newer commit').fetch('run')
      _out, stderr, status = Open3.capture3(env, 'bash', '-c', run)
      raise stderr unless status.success?

      File.read(output).strip
    end
  end

  # Runs the create step with `gh` stubbed: it records its argv and stdin and
  # answers the API's shape (`{"id":7}`).
  def run_create_deployment(sha:)
    Dir.mktmpdir('deploy-demo-create') do |dir|
      stub_dir = File.join(dir, 'bin')
      Dir.mkdir(stub_dir)
      write_stub(stub_dir, 'gh', <<~BASH)
        #!/usr/bin/env bash
        printf '%s\n' "$@" > "$STUB_STATE_DIR/gh_argv"
        cat > "$STUB_STATE_DIR/gh_stdin"
        printf '{"id":7}'
      BASH
      script_path = File.join(dir, 'create.sh')
      File.write(script_path, deployment_step.fetch('run'))
      output_path = File.join(dir, 'github_output')
      env = {
        'PATH' => "#{stub_dir}:#{ENV.fetch('PATH', nil)}",
        'SHA' => sha,
        'GITHUB_REPOSITORY' => 'developerz-ai/wurk',
        'GITHUB_OUTPUT' => output_path,
        'STUB_STATE_DIR' => dir
      }
      _stdout, stderr, status = Open3.capture3(env, 'bash', script_path)

      {
        status: status,
        stderr: stderr,
        gh_argv: read_stub_lines(File.join(dir, 'gh_argv')),
        gh_stdin: File.file?(File.join(dir, 'gh_stdin')) ? File.read(File.join(dir, 'gh_stdin')) : '',
        github_output: File.file?(output_path) ? File.read(output_path) : ''
      }
    end
  end

  # The stubs hold no `#{` and no backslash escapes, so the unquoted
  # heredocs stay literal — bash `$VAR`s pass through untouched.
  def write_probe_stubs(stub_dir)
    write_stub(stub_dir, 'curl', <<~BASH)
      #!/usr/bin/env bash
      n=$(($(cat "$STUB_STATE_DIR/curl_count" 2>/dev/null || echo 0) + 1))
      echo "$n" > "$STUB_STATE_DIR/curl_count"
      echo "$n" >> "$STUB_STATE_DIR/curl_calls"
      if [ -n "$STUB_MATCH_AFTER" ] && [ "$n" -ge "$STUB_MATCH_AFTER" ]; then
        printf '{"sha":"%s"}' "$STUB_EXPECTED"
      elif [ -n "$STUB_BODY" ]; then
        printf '%s' "$STUB_BODY"
      else
        printf '{"sha":"%s"}' "$STUB_SERVED"
      fi
    BASH
    write_stub(stub_dir, 'gh', <<~BASH)
      #!/usr/bin/env bash
      echo "gh $*" >> "$STUB_STATE_DIR/gh_calls"
      case "$*" in
        *compare/*)
          answer="$STUB_COMPARE"
          if [ "$answer" = error-then-ahead ]; then
            if [ -f "$STUB_STATE_DIR/compared" ]; then answer=ahead; else touch "$STUB_STATE_DIR/compared"; answer=error; fi
          fi
          if [ "$answer" = error ]; then echo "gh: Server Error (HTTP 502)" >&2; exit 1; fi
          printf '%s' "$answer"
          ;;
      esac
    BASH
    write_stub(stub_dir, 'sleep', <<~BASH)
      #!/usr/bin/env bash
      # No-op: the probe's sleeps must not slow these tests.
    BASH
  end

  def probe_env(stub_dir, state_dir, expected_sha:, served_sha:, served_body:, match_after:, compare: 'behind',
                allow_newer: 'true', trusted: 'false', has_route: 'true')
    {
      'PATH' => "#{stub_dir}:#{ENV.fetch('PATH', nil)}",
      'EXPECTED_SHA' => expected_sha,
      'ALLOW_NEWER' => allow_newer,
      'TRUSTED' => trusted,
      'HAS_ROUTE' => has_route,
      'STUB_COMPARE' => compare,
      'DEPLOYMENT_ID' => '42',
      'GITHUB_REPOSITORY' => 'developerz-ai/wurk',
      'STUB_STATE_DIR' => state_dir,
      'STUB_SERVED' => served_sha,
      'STUB_BODY' => served_body.to_s,
      'STUB_MATCH_AFTER' => match_after.to_s,
      'STUB_EXPECTED' => expected_sha
    }
  end

  def write_stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  def read_stub_lines(path)
    File.file?(path) ? File.readlines(path, chomp: true) : []
  end

  def authorize_run
    authorize_job.fetch('steps').map { |step| step.fetch('run', '') }.join("\n")
  end
end
