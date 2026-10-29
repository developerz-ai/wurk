# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'yaml'

# Gates the seven graded rows of .dz/briefs/health.md (`main` is green, `the
# last release published`, `the GitHub Release carries the gem`, `the demo
# deployed`, `the demo serves the checkout version`, `topology and ecosystem
# lanes`, `Dependabot is not stuck`) the way release_due_brief_test.rb gates
# release-due.md: these commands run unattended on a schedule, and a verdict
# they cannot actually establish must never be printed as a green one. Twelve
# properties — the first five all pinned by RUNNING the extracted command
# cells as bash against a PATH-stubbed `gh` or `curl` (a substring match over
# the brief's text would accept a guard that never fires), the sixth pinned
# byte-for-byte on the brief's text plus by running the extracted issues
# lookup, and the last four pinned by running the extracted cells as well:
#
#   1. FAIL CLOSED. `gh api .../actions/runs/<id>/jobs` is the only thing
#      between a `gh` error and a false green: with the read empty the row falls
#      through to grading on `conclusion`, printing `success <sha>` for a run
#      it knows nothing about. The row's own word for that state is
#      `evidence unavailable`, and it never reads as green.
#   2. A successful push run grades into EXACTLY ONE named class, read off the
#      job list: `executed` (a gated step ran), `duplicate-skipped` (the tree
#      was reused) or `evidence unavailable` (the list could not be read, or
#      carries no gated job). The conclusion alone cannot tell them apart — a
#      reused tree concludes `success` having run nothing — so the brief has to
#      name the classes AND the evidence they are read from: the job list, the
#      `detect changed paths` job's conclusion, every gated job's conclusion
#      and every gated job's STEP conclusions. CI gates those jobs per STEP
#      (test.yml:153-157), so a dup'd push reports the gated jobs as
#      `success` with every gated step `skipped` — the runner's own `Set up
#      job` and `Complete job` steps excepted, which conclude `success` on a
#      job that did nothing. A job-level `skipped` is a shape no CI run
#      emits, and a classifier reading it graded every dup as a run that
#      executed its gates. The dup signature REQUIRES `detect changed
#      paths` to conclude success. A failed or cancelled detect publishes no
#      outputs, `needs:` skips every dependent before it starts, and the job
#      list comes back with the gated jobs skipped and carrying no steps.
#   3. A release run that published NOTHING still concludes success — the jobs
#      that were skipped do not fail the run — so row 9 reads `preflight`
#      success + `release` skipped and names that a no-op. A run still
#      executing (`conclusion=null`) is reported in flight and graded by
#      nobody.
#   4. A green deploy-demo run proves a pushed image, not a served one: the
#      row reads the `resolve built commit` step log for the `sha-<7>` tag
#      infra's Image Updater selects, and a green run carrying no such tag is
#      Unhealthy — it leaves the demo frozen on an old digest while reporting
#      green. That read is scoped and exact, because a whole `build` job log is
#      full of `sha-<7>`-shaped strings that are not tags: only the named step's
#      lines count, and the match must be a whole token, or the 8-hex full-sha
#      shape wins by prefix and names a tag nothing can ever select. The
#      served version is a separate row's job: it GETs the public demo's
#      `/wurk/api/meta` and compares it with lib/wurk/version.rb.
#   5. Row 15 reads the shape `gh` actually emits. `--json statusCheckRollup`
#      is a LIST of CheckRun/StatusContext entries to roll up, never a state on
#      the PR, so a fixture shaped `{"state": "FAILURE"}` agrees with a read the
#      CLI cannot satisfy and grades a 35-day-old failing PR as "" — the row
#      then prints nothing and reports no stuck dependabot PR, ever. Every
#      fixture below is CLI-shaped for that reason: it is the only thing that
#      lets the stuck assertions fail.
#   6. The filing rule's ask dedupe is executable and mirrors release-due.md:
#      the paragraph carries the byte-identical issues lookup, the lookup
#      really drops PR entries, and ask titles are stable per signal — exact
#      equality on a title that embeds the run's headSha or version can never
#      hit, so the ask would be re-filed on every checkup.
#   7. A release row grades a PUBLICATION, not a workflow run. release.yml
#      concludes `success` on a proceed=false no-op, and a green run whose
#      version never reached RubyGems is the same false green from the other
#      side, so the row refuses to print `success` unless the canonical
#      RubyGems probe serves that version (green + 404 is `Unhealthy: green
#      but empty publication`). The run it grades is bound to the commit
#      that carries Wurk::VERSION — the newest `main` commit that touched
#      lib/wurk/version.rb — so the newest run of any shape can never be
#      graded as this version's release, and a run whose headSha is another
#      sha is refused outright. The version itself is read from that commit
#      (the contents API at the sha), never from the checkout's own copy of
#      the file: a version bump that lands on main after the checkout must
#      not let the newer run certify itself with the older gem's HTTP 200.
#      The GitHub Release is graded on RELEASE.md's
#      gem-less discriminator: an author of `developerz-ai[bot]` OR zero
#      assets is a gem-less Latest Release, and an unreadable lookup grades
#      `verdict unknown` — never a green, never Unhealthy.
#   8. Row 15's read is pinned at runtime. `gh pr list` is asked for the
#      OPEN PRs (`--state open`, never `gh pr list`'s default state) and for
#      the fields the report prints — number, title, createdAt, headRefName,
#      updatedAt, statusCheckRollup, headRefOid — and the stub REFUSES a
#      request that drops either, so a brief that quietly narrowed the read
#      fails closed instead of printing a summary it cannot fill. The report
#      tells an unreadable list (`verdict unknown` AND `not readable`, one
#      line) from a readable empty one (`dependabot: 0 open PRs`), reads the
#      ecosystem off the BRANCH first and the title second, and grades the
#      age off `createdAt` alone — `updatedAt` is reported, never graded.
#   9. The RUN LIST is graded before its contents. Rows 8, 12 and 14 read
#      `gh run list` into a variable and check the list's SHAPE before they
#      extract anything from it, because `jq -c '.[0]'` over a readable `[]`
#      yields the literal string `null` for every field: the jobs call went
#      to `runs/null/jobs`, the read fell into the same catch-all a failed
#      read fell into, and the row printed `verdict unknown null null` — a
#      verdict naming a run that does not exist. So the two shapes are
#      separate findings. An UNREADABLE list (the read failed, or returned
#      a non-array) grades `verdict unknown <workflow>: the run list is not
#      readable` — one line, naming the workflow, never a colour. A
#      READABLE EMPTY list is its own outcome, `no run: <workflow> has no
#      matching run`, carrying no sha and no url because no run exists to
#      link; it is neither `verdict unknown` nor Unhealthy, and the filing
#      rule says it files no ask. Row 9's own release-run read keeps its
#      `verdict unknown` grade on an empty list, and row 15's dependabot
#      read already told an unreadable list (`verdict unknown` AND
#      `not readable`) from a readable empty one (`dependabot: 0 open PRs`).
#      The stub serves both shapes from a per-workflow `<wf>.runs` fixture,
#      so the four-fixture default path is unchanged.
#  10. gh's EXIT STATUS is graded beside the list's shape. gh can fail after
#      the array has already landed on stdout, so a perfectly good JSON array
#      can be the bytes of a FAILED read — and the failed-read contract names
#      the non-zero exit as its own unreadable shape. The rows capture the
#      exit status out of the command substitution and test it BEFORE the
#      array is inspected, so a half-failed read (the stub's `error-empty` and
#      `error-run` shapes) grades `verdict unknown`: never the named `no run:`
#      outcome, never a verdict graded off the emitted bytes.
#  11. A past-budget red DOCKER bump whose title matches a bun-pin shape
#      (`^Bump <dep>/<name> from` or ` group with .* updates$`) is WAITING ON
#      US, not stuck: dependabot cannot edit the four matching bun pin sites
#      (dependabot.yml:63-74 — the bun-version inputs in test.yml and
#      release.yml, bun in mise.toml, the oven/bun FROM in docs/deployment.md),
#      so the row prints `Unhealthy: Docker bump #<n> is waiting on us: ...`
#      and suppresses the stuck line for that PR — the ask names the owner
#      (the maintainer agent pushes the pin edits to the branch) instead of
#      filing author-inactivity against the actor that cannot act. The
#      predicate still requires the FAILURE rollup and the strictly-past age,
#      so a young red docker PR prints neither verdict, and a red docker PR
#      with a non-matching title stays genuinely stuck.
#  12. The waiting-on-us classification VERIFIES an outstanding pin mismatch
#      at the PR's head before it claims the title shape. A title plus a red
#      rollup cannot tell "the pins are still outstanding" from "the pin
#      edits already landed and something else is red" — graded on the title
#      alone, an old oven/bun PR with matching pins prints `push the pin
#      edits` forever and suppresses the stuck verdict indefinitely, so the
#      row reads the five bun pin sites at headRefOid through the contents
#      API and classifies waiting-on-us only when they still disagree. Pins
#      agreeing at the head fall through to stuck (the regression fixture:
#      pins fixed, CI still red); a failed pin read verifies nothing and
#      prints `verdict unknown ... not readable`, filing no ask for that
#      PR. A failed read includes the HALF-FAILED shape: on a 404 or a rate
#      limit `gh api` emits a nonempty JSON error body and exits non-zero,
#      so each site's exit status is captured beside its bytes and graded
#      before them — a row that parsed the body alone would extract no pin
#      from the error JSON and grade the failed read an outstanding
#      mismatch, filing the false waiting-on-us ask.
#
# One more property, added with the run URLs: every job-list row must request
# BOTH `url` and `databaseId` and print the URL on EVERY verdict — dup,
# graded, unknown, no-op, in flight. The brief's filing rule says an ask's body
# carries "the command, its output and the run URL", so the rows have to carry
# the URL themselves; a `--json` list that silently lost `url` would leave
# `jq -r .url` printing the string `null`, and the ask would link nowhere.
# STUB_GH therefore serves a fixture-backed `url` — otherwise the row under test
# would print a bogus URL and the exact-stdout assertions would be pinning it.
#
# Reads the brief and runs its own extracted commands; no network, no Redis,
# no shared state.
class HealthBriefTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  BRIEF = File.join(ROOT, '.dz', 'briefs', 'health.md')
  RELEASE_DUE_BRIEF = File.join(ROOT, '.dz', 'briefs', 'release-due.md')
  RELEASE_WORKFLOW = File.join(ROOT, '.github', 'workflows', 'release.yml')

  SHA_DUP        = 'd' * 40
  SHA_GREEN      = 'a' * 40
  SHA_RED        = '8' * 40
  SHA_TOPOLOGY   = 'c' * 40
  SHA_ECOSYSTEM  = 'e' * 40
  SHA_PUBLISHED  = 'b' * 40
  SHA_NOOP       = 'f' * 40
  SHA_REFUSED    = '9' * 40
  SHA_INFLIGHT   = '1' * 40
  SHA_DEMO       = '7' * 40
  SHA_DEMO_FROZEN = '4' * 40
  # Head SHAs for the dependabot PRs row 15 reports — one per ecosystem, so
  # a report line can be told apart from the PR number it carries.
  SHA_RUBOCOP    = '5' * 40
  SHA_TYPES      = '6' * 40
  SHA_ACTIONS    = '3' * 40
  SHA_DOCKER     = '2' * 40
  SHA_PR         = '0' * 40
  # The bun versions the row-15 pin fixtures carry: BUN_OLD is what every
  # non-Dockerfile site still names on a dependabot-only head, BUN_NEW what
  # the pushed pin edits land.
  BUN_OLD        = '1.4.1'
  BUN_NEW        = '1.4.2'
  # The stdout body a real `gh api` writes when a contents read fails — a
  # 404 or a rate limit — BEFORE it exits non-zero. The pin-site stub serves
  # it from a `pin.<site>.error` marker, so the row is pinned against the
  # failed read that carries bytes, not only the silent empty one.
  PIN_ERROR_BODY = '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/contents"}'
  # A sha that is NOT the commit carrying Wurk::VERSION: the release run
  # that carries it says nothing about this version's release, so the row
  # must refuse it.
  SHA_OTHER      = '8' * 40
  DEMO_TAG       = 'sha-7777777'
  API_CONTROLLER = File.join(ROOT, 'app', 'controllers', 'wurk', 'api_controller.rb')

  # The three classes a successful push run grades into, read off the job
  # list. A verdict names EXACTLY ONE of them: the run's conclusion alone
  # cannot tell them apart — a reused tree concludes `success` having run
  # nothing at all.
  CLASSIFICATIONS = ['executed', 'duplicate-skipped', 'evidence unavailable'].freeze

  # The job DISPLAY names the brief's runtime rows select on: rows 8 and 14
  # filter the jobs list on `.name == "detect changed paths"`, and row 15's
  # pins discriminator plus this file's own fixtures name
  # `test + coverage (latest ruby/rails)` and `lint (rubocop)`. Each of them
  # is the `name:` of a job in test.yml.
  JOB_NAME_SELECTORS = ['detect changed paths',
                        'test + coverage (latest ruby/rails)',
                        'lint (rubocop)'].freeze

  # deploy-demo.yml's step names. `gh run view --log` carries one in field 2 of
  # every line it prints, and row 12 keeps only the first one's lines.
  RESOLVE_STEP = 'resolve built commit'
  VERIFY_STEP = 'verify pushed tags resolve'
  # A `verify pushed tags resolve` line naming the ref it inspected
  # (deploy-demo.yml:207-209) — the shape a whole-log grep reads as a tag.
  DECOY_REF = '==> inspecting registry.digitalocean.com/developerz-ai/wurk-demo:sha-1234567'

  URL_TEST        = 'https://github.com/wurk-owner/wurk/actions/runs/1'
  URL_RELEASE     = 'https://github.com/wurk-owner/wurk/actions/runs/201'
  URL_DEMO        = 'https://github.com/wurk-owner/wurk/actions/runs/301'
  URL_TOPOLOGY    = 'https://github.com/wurk-owner/wurk/actions/runs/101'
  URL_ECOSYSTEM   = 'https://github.com/wurk-owner/wurk/actions/runs/102'

  def setup
    @text = File.read(BRIEF)
  end

  # The runtime rows select jobs by their DISPLAY name: rows 8 and 14 filter
  # the jobs list on `.name == "detect changed paths"` / `.name != ...`, and
  # row 15's pins discriminator plus this file's own fixtures name
  # `test + coverage (latest ruby/rails)` and `lint (rubocop)`. Each of those
  # strings is the `name:` of a job in test.yml — rename one there without
  # updating the selector and the jq filter silently matches nothing, turning
  # a real gate's absence into `evidence unavailable`. The check is
  # membership, not equality: unrelated jobs may come and go.
  def test_the_job_name_selectors_match_a_test_yml_job_display_name
    assert_job_name_selectors_present(workflow_jobs)
  end

  # A guard that cannot fail is not a guard: the membership check has to
  # REJECT a renamed job. Rename a job in test.yml without updating the
  # selector and the jq filter matches nothing in CI — every gated job
  # grades as absent, and a real gate's absence becomes `evidence
  # unavailable`.
  def test_the_job_name_selector_guard_rejects_a_renamed_workflow_job
    jobs = workflow_jobs
    job = jobs.values.find { |spec| spec['name'] == 'lint (rubocop)' }

    flunk 'test.yml declares no job named `lint (rubocop)` to rename' if job.nil?

    job['name'] = 'lint (rubo)'

    refute_includes workflow_job_names(jobs), 'lint (rubocop)',
                    'the rename must have landed before the guard is exercised'

    violations = job_name_selector_violations(jobs)

    refute_empty violations,
                 'renaming a job in test.yml without updating the selector must ' \
                 "fail the guard (violations: #{violations.inspect})"

    error = assert_raises(Minitest::Assertion) { assert_job_name_selectors_present(jobs) }

    assert_includes error.message, 'lint (rubocop)',
                    'the guard must fail BECAUSE the renamed selector lost its job'
  end

  # ... and the check is MEMBERSHIP, not equality: test.yml's job list may
  # grow — an unrelated job must not fail the guard.
  def test_the_job_name_selector_guard_accepts_an_unrelated_added_job
    jobs = workflow_jobs
    before = jobs.size

    jobs['brand-new-job'] = { 'name' => 'brand new job' }

    assert_equal before + 1, jobs.size,
                 'the added job must have landed before the guard is exercised'

    violations = job_name_selector_violations(jobs)

    assert_empty violations,
                 'the selector check is membership, not equality: an unrelated ' \
                 "job may come and go (violations: #{violations.inspect})"

    assert_job_name_selectors_present(jobs)
  end

  def test_dup_push_run_with_every_gated_step_skipped_is_duplicate_skipped
    # A run whose `detect changed paths` concluded success and whose every
    # gated job reported `success` with every one of its steps `skipped` —
    # the runner's own `Set up job` and `Complete job` excepted, both of
    # which conclude `success` on a job whose gate never ran — reused a tree
    # that already passed that workflow. CI gates those jobs per
    # STEP (test.yml:153-157), so that — not a job-level `skipped` — is the
    # shape a dup'd push produces. It is neither a green the row did not earn
    # nor a failure: the verdict names the reuse and the push files no ask.
    out, err, status = run_row8(jobs: jobs_json(detect: 'success', gate: 'skipped'),
                                conclusion: 'success', sha: SHA_DUP)

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'duplicate-skipped',
                    'a run whose `detect changed paths` concluded success and whose ' \
                    'every gated step came back `skipped` reused a tree that already ' \
                    "passed — the verdict must name that class; got stdout=#{out.inspect}"

    assert_includes out, 'the gated steps were skipped; the tree already passed that workflow',
                    'the verdict must NAME the reuse: a reused tree is neither "the ' \
                    "tests executed\" nor a failure; got stdout=#{out.inspect}"

    assert_includes out, SHA_DUP,
                    'the verdict must surface the headSha of the run that reused the ' \
                    "tree; got stdout=#{out.inspect}"

    assert_includes out, URL_TEST,
                    "the verdict must carry the run url; got #{out.inspect}"

    refute_includes out, 'Unhealthy',
                    'a reused tree is not broken — the tree already passed that ' \
                    "workflow, so the push files no ask; got stdout=#{out.inspect}"

    refute_includes out, 'failure',
                    "a reused tree is not a failure; got stdout=#{out.inspect}"

    refute_match(/\bsuccess\b/, out,
                 'the verdict must not print a green `success` it did not earn: the ' \
                 "gated steps never ran; got stdout=#{out.inspect}")

    assert_equal ['duplicate-skipped'], classifications(out),
                 'a successful push grades exactly one class'
  end

  def test_run_whose_gated_jobs_actually_ran_grades_executed
    out, err, status = run_row8(jobs: jobs_json(detect: 'success', gate: 'success'),
                                conclusion: 'success', sha: SHA_GREEN)

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["executed: success #{SHA_GREEN} #{URL_TEST}"], out.lines.map(&:chomp),
                 'gated jobs that really ran make this an ordinary main run: the row ' \
                 'grades it `executed`, carrying the run\'s conclusion, sha and url'

    refute_includes out, 'Unhealthy',
                    'a run whose gated jobs succeeded is not a dup'
    refute_includes out, 'duplicate-skipped',
                    'a run whose gated jobs succeeded is not a reused tree'
    refute_includes out, 'evidence unavailable',
                    'a readable jobs list is a verdict, not an unknown'

    assert_equal ['executed'], classifications(out),
                 'a successful push grades exactly one class'
  end

  def test_unreadable_jobs_list_grades_evidence_unavailable
    out, err, _status = run_row8(jobs: jobs_json(detect: 'success', gate: 'skipped'),
                                 conclusion: 'success', sha: SHA_DUP, jobs_fail: true)

    refute_includes out, "success #{SHA_DUP}",
                    'the `gh api .../jobs` stub failed, so the jobs list is ' \
                    'unreadable and the row knows nothing about what ran; it must ' \
                    'not fall through to grading on conclusion and print a false ' \
                    "green (stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'evidence unavailable',
                    'an unreadable jobs list must surface as `evidence unavailable` ' \
                    "so the next checkup re-runs it; got stdout=#{out.inspect}"

    refute_match(/\bsuccess\b/, out,
                 'an unreadable jobs list never reads as green; ' \
                 "got stdout=#{out.inspect}")

    assert_includes out, SHA_DUP,
                    '`evidence unavailable` must still name the sha it could not ' \
                    "grade, so the ask can link the run; got stdout=#{out.inspect}"

    assert_includes out, URL_TEST,
                    '`evidence unavailable` must still carry the run url; ' \
                    "got stdout=#{out.inspect}"

    assert_equal ['evidence unavailable'], classifications(out),
                 'a successful push grades exactly one class'
  end

  def test_a_successful_run_with_no_gated_job_grades_evidence_unavailable
    # The job list was readable, but it carries no gated job at all: there is
    # no evidence of execution in it, so the row must not certify the run on
    # its conclusion alone.
    out, err, status = run_row8(jobs: jobs_json_without_gated_jobs(detect: 'success'),
                                conclusion: 'success', sha: SHA_GREEN)

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'evidence unavailable',
                    'a job list carrying no gated job holds no evidence of ' \
                    "execution; got stdout=#{out.inspect}"

    refute_match(/\bsuccess\b/, out,
                 'a job list carrying no gated job never reads as green; ' \
                 "got stdout=#{out.inspect}")

    assert_equal ['evidence unavailable'], classifications(out),
                 'a successful push grades exactly one class'
  end

  def test_failed_detect_is_not_read_as_a_dup
    # The counterexample to "every gated step skipped means dup and nothing
    # else": a `detect` that fails or is cancelled publishes no outputs,
    # `needs:` then skips every dependent before it starts, and the job list
    # comes back with the gated jobs reporting `skipped` and carrying no
    # steps. The run's own conclusion is `failure`, and that — not a dup'd PR
    # run — is why nothing ran.
    out, err, status = run_row8(jobs: jobs_json_after_failed_detect,
                                conclusion: 'failure', sha: SHA_DUP)

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["failure #{SHA_DUP} #{URL_TEST}"], out.lines.map(&:chomp),
                 'a failed `detect` skips every dependent via `needs:` before it ' \
                 'starts, so the gated jobs report `skipped` and carry no steps, ' \
                 "and the dup signature must require detect's own success; got stdout=#{out.inspect}"

    refute_includes out, 'duplicate-skipped',
                    'a failed `detect` is not a reused tree: the run grades on its own ' \
                    "conclusion; got stdout=#{out.inspect}"
  end

  def test_a_red_run_grades_on_its_own_conclusion
    # The classification only covers a green run: a red one grades on its own
    # conclusion, exactly as it always did.
    out, err, status = run_row8(jobs: jobs_json(detect: 'success', gate: 'failure'),
                                conclusion: 'failure', sha: SHA_RED)

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["failure #{SHA_RED} #{URL_TEST}"], out.lines.map(&:chomp),
                 "a red run grades on its own conclusion (stdout=#{out.inspect})"

    refute_includes out, 'executed',
                    'a red run is not `executed`: the gated steps did not all pass'
    refute_includes out, 'duplicate-skipped',
                    'a red run is not a reused tree'
    assert_includes out, URL_TEST,
                    "a red run's verdict must still carry the run url; got #{out.inspect}"
  end

  # A READABLE but EMPTY run list is its own outcome, and it is not the
  # unreadable one. The old cell ran `jq -c '.[0]'` over the list without
  # looking at its shape, so `[]` yielded the literal string `null` for
  # every field, the jobs call went to `runs/null/jobs`, and the row fell
  # into the same catch-all a failed read fell into — printing
  # `verdict unknown null null`: a verdict naming nothing, carrying a run
  # that does not exist. The row now names the outcome and the workflow.
  def test_row8_empty_run_list_is_a_named_no_run_outcome
    out, err, status = run_row8(jobs: jobs_json(detect: 'success', gate: 'skipped'),
                                conclusion: 'success', sha: SHA_GREEN, runs: :empty)

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 1, lines.size,
                 "an empty run list prints exactly one line; got #{lines.inspect}"

    assert_match(/\Ano run: test\.yml has no matching run\z/, lines.first,
                 'a readable but empty run list is its own outcome: the row names it ' \
                 "and the workflow it asked about; got #{lines.inspect}")

    refute_includes out, 'verdict unknown',
                    'an empty run list is a READABLE answer, not an unreadable one — ' \
                    "the two findings must never look alike (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    'no run exists to grade, so nothing failed; the empty outcome is not ' \
                    "a red one and files no ask (stdout=#{out.inspect})"

    refute_includes out, 'null',
                    'the empty outcome carries no sha and no url — there is no run to ' \
                    'link, and a literal `null` field is the defect this replaces ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'success',
                    "an empty run list is not a green main either (stdout=#{out.inspect})"
  end

  # The other arm of the same rule: an UNREADABLE run list (the read failed,
  # so `gh` wrote nothing) grades `verdict unknown` and says the list was
  # not readable — the same one-line shape row 15 states for the PR list.
  # It is a different finding from the empty one above and must not look
  # like it.
  def test_row8_unreadable_run_list_grades_verdict_unknown_not_readable
    out, err, status = run_row8(jobs: jobs_json(detect: 'success', gate: 'skipped'),
                                conclusion: 'success', sha: SHA_GREEN, runs: :fail)

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 1, lines.size,
                 "an unreadable run list prints exactly one line; got #{lines.inspect}"

    assert_includes lines.first, 'verdict unknown',
                    'a run list the row could not read establishes nothing, so it fails ' \
                    "closed as `verdict unknown` (stdout=#{out.inspect})"

    assert_includes lines.first, 'not readable',
                    'the line must also say the list was NOT READABLE: an unreadable ' \
                    'list and an empty one are different findings and must never look ' \
                    "alike (stdout=#{out.inspect})"

    assert_includes lines.first, 'test.yml',
                    'the line must name the workflow it could not read a run list for; ' \
                    "got #{lines.first.inspect}"

    refute_includes out, 'Unhealthy',
                    'an unreadable list is not evidence that the run failed; ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, "success #{SHA_GREEN}",
                    'a run list the row could not read cannot certify a green main; ' \
                    "(stdout=#{out.inspect})"
  end

  # gh can fail AFTER the array has already landed on stdout, so the captured
  # bytes can be a perfectly good JSON array from a read that failed — and the
  # failed-read contract names the non-zero exit as its own unreadable shape.
  # A row that inspected the array alone would print the named `no run:`
  # outcome here: a readable-empty answer for a read that failed.
  def test_row8_nonzero_exit_with_an_empty_json_stdout_is_not_a_no_run
    out, err, status = run_row8(jobs: jobs_json(detect: 'success', gate: 'skipped'),
                                conclusion: 'success', sha: SHA_GREEN, runs: 'error-empty')

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 1, lines.size,
                 "a half-failed read prints exactly one line; got #{lines.inspect}"

    assert_includes lines.first, 'verdict unknown',
                    'gh exited non-zero after emitting the list, so the read FAILED and the ' \
                    "row must fail closed (stdout=#{out.inspect})"

    assert_includes lines.first, 'not readable',
                    'the line must say the list was not readable — the same finding as a read ' \
                    "that wrote nothing (stdout=#{out.inspect})"

    assert_includes lines.first, 'test.yml',
                    'the line must name the workflow it could not read a run list for; ' \
                    "got #{lines.first.inspect}"

    refute_includes out, 'no run:',
                    'a read that exited non-zero is not a readable empty list: printing the ' \
                    'named `no run:` outcome for it contradicts the failed-read contract ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    "a failed read is not evidence that the run failed (stdout=#{out.inspect})"
  end

  # The same half-failed read with a run in it: the emitted bytes must not be
  # graded, because their read failed — grading them would print the green the
  # run's own exit status disowns.
  def test_row8_nonzero_exit_with_a_json_array_grades_nothing
    out, err, status = run_row8(jobs: jobs_json(detect: 'success', gate: 'success'),
                                conclusion: 'success', sha: SHA_GREEN, runs: 'error-run')

    assert_predicate status, :success?,
                     "row 8's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 1, lines.size,
                 "a half-failed read prints exactly one line; got #{lines.inspect}"

    assert_includes lines.first, 'verdict unknown',
                    'gh exited non-zero after emitting the run, so the read failed and nothing ' \
                    "may be graded off its bytes (stdout=#{out.inspect})"

    refute_match(/\bexecuted\b/, out,
                 'the emitted run must not be classified: its read failed; ' \
                 "(stdout=#{out.inspect})")

    refute_includes out, "success #{SHA_GREEN}",
                    'a half-failed read cannot certify a green main ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, URL_TEST,
                    'the emitted bytes are disowned by their failed read, so the url must not ' \
                    "be printed as a verdict (stdout=#{out.inspect})"
  end

  def test_row14_classifies_both_lanes_and_names_each_workflow
    # topology.yml reused a tree, ecosystem.yml ran its gated job: each line
    # must name its own lane, its own class and its own run, or the reader
    # cannot tell which workflow to go look at.
    out, err, status = run_row14

    assert_predicate status, :success?,
                     "row 14's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 2, lines.size,
                 "row 14 prints one line per lane; got #{lines.inspect}"

    topology = lines.find { |line| line.start_with?('topology.yml') }
    ecosystem = lines.find { |line| line.start_with?('ecosystem.yml') }

    refute_nil topology,
               "the topology.yml lane must print its own line; got #{lines.inspect}"
    refute_nil ecosystem,
               "the ecosystem.yml lane must print its own line; got #{lines.inspect}"

    assert_includes topology, 'duplicate-skipped',
                    'topology.yml reused a tree, so its line must name that class; ' \
                    "got #{topology.inspect}"

    assert_includes topology, 'the gated steps were skipped; the tree already passed that workflow',
                    "the topology.yml line must name the reuse, like row 8's verdict " \
                    "does; got #{topology.inspect}"

    assert_includes topology, SHA_TOPOLOGY,
                    'the topology.yml line must carry its own headSha; ' \
                    "got #{topology.inspect}"

    assert_includes topology, URL_TOPOLOGY,
                    "the topology.yml line must carry its own run url; got #{topology.inspect}"

    assert_equal ['duplicate-skipped'], classifications(topology),
                 'the topology.yml line grades exactly one class'

    assert_includes ecosystem, 'executed',
                    'ecosystem.yml ran its gated job, so its line must name that ' \
                    "class; got #{ecosystem.inspect}"

    assert_includes ecosystem, SHA_ECOSYSTEM,
                    'the ecosystem.yml line must carry its own headSha; ' \
                    "got #{ecosystem.inspect}"

    assert_includes ecosystem, URL_ECOSYSTEM,
                    "the ecosystem.yml line must carry its own run url; got #{ecosystem.inspect}"

    assert_equal ['executed'], classifications(ecosystem),
                 'the ecosystem.yml line grades exactly one class'

    refute_includes out, 'Unhealthy',
                    'a reused tree is not broken — neither lane files an ask for it; ' \
                    "got #{out.inspect}"
  end

  def test_row14_fails_closed_when_the_jobs_list_is_unreadable
    out, err, status = run_row14(jobs_fail: true)

    assert_predicate status, :success?,
                     "row 14's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 2, lines.size,
                 "row 14 prints one line per lane; got #{lines.inspect}"

    lines.each do |line|
      assert_includes line, 'evidence unavailable',
                      'an unreadable jobs list must grade `evidence unavailable`; ' \
                      "got #{line.inspect}"

      refute_match(/\bsuccess\b/, line,
                   'an unreadable jobs list never reads as green; ' \
                   "got #{line.inspect}")
    end

    assert_includes out, SHA_TOPOLOGY,
                    'the topology.yml lane must still name its own sha; ' \
                    "got #{out.inspect}"
    assert_includes out, URL_TOPOLOGY,
                    'the topology.yml lane must still carry its own run url; ' \
                    "got #{out.inspect}"
    assert_includes out, SHA_ECOSYSTEM,
                    'the ecosystem.yml lane must still name its own sha; ' \
                    "got #{out.inspect}"
    assert_includes out, URL_ECOSYSTEM,
                    'the ecosystem.yml lane must still carry its own run url; ' \
                    "got #{out.inspect}"
  end

  def test_row14_fails_closed_when_a_lane_carries_no_gated_job
    # `sidekiq release watcher` is ecosystem.yml's schedule/dispatch-only job:
    # on a push it reports `skipped` with no steps, and row 14 excludes it by
    # name because it is never gated on dup. A lane whose job list therefore
    # carries no gated job at all holds no evidence of execution — the row
    # must fail closed instead of reading the watcher's skip as a reuse.
    out, err, status = run_row14(topology: jobs_json_without_gated_jobs(detect: 'success', watcher: true))

    assert_predicate status, :success?,
                     "row 14's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 2, lines.size,
                 "row 14 prints one line per lane; got #{lines.inspect}"

    topology = lines.find { |line| line.start_with?('topology.yml') }
    ecosystem = lines.find { |line| line.start_with?('ecosystem.yml') }

    assert_includes topology, 'evidence unavailable',
                    'a lane whose job list carries no gated job holds no evidence of ' \
                    "execution; got #{topology.inspect}"

    assert_includes topology, 'the jobs list carries no gated job',
                    'the excluded watcher is not a gated job, so the lane holds no ' \
                    "evidence of execution at all; got #{topology.inspect}"

    refute_match(/\bsuccess\b/, topology,
                 'a lane with no gated job never reads as green; ' \
                 "got #{topology.inspect}")

    refute_includes topology, 'duplicate-skipped',
                    'the excluded watcher is not a gated job, so its skip is not a ' \
                    "reuse; got #{topology.inspect}"

    assert_includes topology, SHA_TOPOLOGY,
                    'the topology.yml line must still name its own sha; ' \
                    "got #{topology.inspect}"

    assert_includes topology, URL_TOPOLOGY,
                    "the topology.yml line must still carry its own run url; got #{topology.inspect}"

    assert_equal ['evidence unavailable'], classifications(topology),
                 'the topology.yml line grades exactly one class'

    assert_includes ecosystem, 'executed',
                    "the other lane is unaffected by its neighbour's missing evidence; " \
                    "got #{ecosystem.inspect}"
  end

  # Row 14 grades two lanes in one loop, so an empty run list has to be
  # named PER LANE: the reader has to know which workflow has no run.
  def test_row14_empty_run_lists_name_each_lane
    out, err, status = run_row14(runs: :empty)

    assert_predicate status, :success?,
                     "row 14's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal ['no run: topology.yml has no matching run',
                  'no run: ecosystem.yml has no matching run'], lines,
                 'each lane with an empty run list names itself and prints no sha and ' \
                 "no url; got #{lines.inspect}"

    refute_includes out, 'verdict unknown',
                    'an empty run list is a readable answer, not an unreadable one ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    "no run exists to grade, so nothing failed (stdout=#{out.inspect})"

    refute_includes out, 'null',
                    'the empty outcome carries no `null` field — that is the defect it ' \
                    "replaces (stdout=#{out.inspect})"
  end

  # The unreadable arm of the same rule for row 14: each lane whose run
  # list could not read fails closed as `verdict unknown` and says the list
  # was NOT READABLE — a different finding from the readable-empty outcome
  # above.
  def test_row14_unreadable_run_lists_name_each_lane
    out, err, status = run_row14(runs: :fail)

    assert_predicate status, :success?,
                     "row 14's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal ['verdict unknown topology.yml: the run list is not readable ' \
                  '(gh run list failed or returned a non-array)',
                  'verdict unknown ecosystem.yml: the run list is not readable ' \
                  '(gh run list failed or returned a non-array)'], lines,
                 'each lane whose run list could not be read names itself, says ' \
                 "`verdict unknown` and says the list was not readable; got #{lines.inspect}"

    lines.each do |line|
      assert_includes line, 'verdict unknown',
                      'an unreadable run list establishes nothing, so the lane fails ' \
                      "closed (stdout=#{out.inspect})"

      assert_includes line, 'not readable',
                      'the line must also say the list was NOT READABLE: an unreadable ' \
                      'list and an empty one are different findings and must never look ' \
                      "alike (stdout=#{out.inspect})"
    end

    assert_includes lines.first, 'topology.yml',
                    'the line must name the workflow it could not read a run list for; ' \
                    "got #{lines.first.inspect}"

    assert_includes lines.last, 'ecosystem.yml',
                    'the line must name the workflow it could not read a run list for; ' \
                    "got #{lines.last.inspect}"

    refute_includes out, 'Unhealthy',
                    'an unreadable list is not evidence that the run failed; ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'null',
                    'an unreadable list has no run to carry a sha or a url; ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, ' success ',
                    'a run list the row could not read cannot certify a green lane; ' \
                    "(stdout=#{out.inspect})"
  end

  # The half-failed read, per lane: a lane whose `gh run list` exits non-zero
  # after emitting its list fails closed off the EXIT STATUS — the empty-`[]`
  # lane must not print its named `no run:` outcome (topology.yml below), and
  # the run-carrying lane must not grade the emitted run (ecosystem.yml below).
  def test_row14_nonzero_exit_with_json_stdout_fails_closed_per_lane
    out, err, status = run_row14(runs: { 'topology.yml' => 'error-empty',
                                         'ecosystem.yml' => 'error-run' })

    assert_predicate status, :success?,
                     "row 14's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 2, lines.size,
                 "row 14 prints one line per lane; got #{lines.inspect}"

    topology = lines.find { |line| line.include?('topology.yml') }
    ecosystem = lines.find { |line| line.include?('ecosystem.yml') }

    refute_nil topology,
               "the topology.yml lane must print its own line; got #{lines.inspect}"
    refute_nil ecosystem,
               "the ecosystem.yml lane must print its own line; got #{lines.inspect}"

    assert_includes topology, 'verdict unknown',
                    'gh exited non-zero after emitting the list, so the read FAILED and the ' \
                    "lane must fail closed; got #{topology.inspect}"

    assert_includes topology, 'not readable',
                    "the line must say the list was not readable; got #{topology.inspect}"

    refute_includes topology, 'no run:',
                    'a read that exited non-zero is not a readable empty list; ' \
                    "got #{topology.inspect}"

    assert_includes ecosystem, 'verdict unknown',
                    'gh exited non-zero after emitting the run, so nothing may be graded off ' \
                    "its bytes; got #{ecosystem.inspect}"

    refute_match(/\bexecuted\b/, ecosystem,
                 'the emitted run must not be classified: its read failed; ' \
                 "got #{ecosystem.inspect}")

    refute_includes out, ' success ',
                    'a half-failed read cannot certify a green lane; ' \
                    "(stdout=#{out.inspect})"
  end

  # One lane empty and the other readable: the empty lane names itself and
  # the readable lane still grades on its own conclusion. The empty outcome
  # must not swallow the other lane's verdict.
  def test_row14_one_empty_lane_leaves_the_other_lane_graded
    out, err, status = run_row14(runs: { 'topology.yml' => :empty })

    assert_predicate status, :success?,
                     "row 14's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal ['no run: topology.yml has no matching run',
                  "ecosystem.yml executed: success #{SHA_ECOSYSTEM} #{URL_ECOSYSTEM}"], lines,
                 'the empty lane names itself and the lane that has a run still grades — ' \
                 'with the gated steps graded, the readable lane classifies as `executed` ' \
                 "rather than printing its bare conclusion; got #{lines.inspect}"

    refute_includes out, 'Unhealthy',
                    "an empty lane is not a red lane (stdout=#{out.inspect})"
  end

  # Pins the recovery paragraph in .dz/briefs/health.md — the prose a
  # red-main or release-failure ask points the responder at. The checkup
  # lane's ONLY admissible response to a red signal is filing one deduped ask
  # for a maintainer (health.md's filing rule); RELEASE.md owns the recovery
  # runbook, and this paragraph is a pointer at it, never a command list this
  # lane runs. Four properties have to hold so it neither re-arms the checkup
  # nor silently forbids something the runbook prescribes:
  #
  #   1. The paragraph names filing (or deduping) an ask as the checkup's
  #      admissible response. A paragraph that drops that framing hands the
  #      unattended checkup lane the recovery commands to run itself — the
  #      defect this pin was added with.
  #   2. The paragraph SCOPES its prohibitions to the checkup lane (a "from
  #      this lane" / "the checkup never" framing). An unscoped "never
  #      re-tag / never gem push" reads as forbidding the maintainer's own
  #      runbook steps, shadowing the very runbook the ask points at.
  #   3. The paragraph NAMES the runbook steps it points at: both
  #      headings — *If a release fails* and *Recovering a gem-less
  #      release* — and the two commands the gem-less subsection actually
  #      prescribes (`gh release delete ... --cleanup-tag`, then
  #      `git fetch --prune-tags`). Pin them with a substring assertion
  #      over the joined paragraph — markdown italic can wrap across a
  #      line break, so the assertion reads the paragraph as one string.
  #   4. The paragraph does NOT forbid the sanctioned steps the rest of
  #      the runbook prescribes: the `workflow_dispatch` retry (used to
  #      re-run a release whose run failed after the bump was merged) and
  #      the break-glass hand create (only when CI is unavailable). A
  #      "Never ... workflow_dispatch" or "Never ... break-glass" sentence
  #      would shadow the runbook it claims to point at. Pin the absence.
  #
  # Reads only the brief as text — no shell, no fixtures.
  def test_recovery_paragraph_follows_release_md_runbook
    assert_recovery_paragraph(@text)
  end

  def test_recovery_guard_rejects_a_prohibition_at_the_end_of_the_paragraph
    text = "Extra introductory paragraph.\n\n#{@text.rstrip} Never use break-glass.\n"

    error = assert_raises(Minitest::Assertion) { assert_recovery_paragraph(text) }
    assert_includes error.message, 'must not forbid the break-glass'
  end

  def test_recovery_guard_rejects_wrapped_workflow_dispatch_prohibition
    text = @text.sub('That cleanup', "Never\nuse workflow_dispatch. That cleanup")

    error = assert_raises(Minitest::Assertion) { assert_recovery_paragraph(text) }
    assert_includes error.message, 'must not forbid the `workflow_dispatch`'
  end

  def test_recovery_guard_rejects_wrapped_break_glass_prohibition
    text = @text.sub('That cleanup', "Never\nuse break-glass. That cleanup")

    error = assert_raises(Minitest::Assertion) { assert_recovery_paragraph(text) }
    assert_includes error.message, 'must not forbid the break-glass'
  end

  def test_recovery_guard_accepts_the_paragraph_after_line_numbers_change
    assert_recovery_paragraph("Extra introductory paragraph.\n\n#{@text}")
  end

  def assert_recovery_paragraph(text)
    paragraph = text.split(/\n[ \t]*\n/).find { |part| part.include?('Recovery is') }

    refute_nil paragraph, 'health.md must contain the recovery paragraph'

    # Markdown wrapping must not hide a prohibition, but a "never" in an
    # earlier sentence must not forbid a later, sanctioned recovery step.
    paragraph = paragraph.gsub(/\s+/, ' ')

    assert_match(/file\b[^.!?]*\b(?:one )?ask\b|\bask\b[^.!?]*\bfile\b/i,
                 paragraph,
                 'recovery paragraph in health.md must name filing one (deduped) ask as ' \
                 'the checkup lane\'s admissible response to a red signal — without that ' \
                 'framing the paragraph hands the unattended lane the recovery commands ' \
                 "to run itself; got paragraph=#{paragraph.inspect}")

    assert_match(/from this lane|the checkup\b[^.!?]*\bnever/i,
                 paragraph,
                 'recovery paragraph in health.md must scope its prohibitions to the ' \
                 'checkup lane (a "from this lane" / "the checkup never" framing) — an ' \
                 'unscoped "never re-tag / never gem push" reads as forbidding the ' \
                 "maintainer's own runbook steps; got paragraph=#{paragraph.inspect}")

    assert_includes paragraph, 'If a release',
                    'recovery paragraph in health.md must name the ' \
                    "'If a release ... ' heading reference so the reader knows " \
                    "where to go; got paragraph=#{paragraph.inspect}"

    assert_match(/fails\*\./, paragraph,
                 'recovery paragraph in health.md must close the ' \
                 "'... fails*' italic heading reference; got paragraph=#{paragraph.inspect}")

    assert_includes paragraph, 'Recovering a gem-less release',
                    'recovery paragraph in health.md must name RELEASE.md\'s ' \
                    "'Recovering a gem-less release' heading — the subsection that " \
                    'actually prescribes the cleanup commands; ' \
                    "got paragraph=#{paragraph.inspect}"

    assert_match(/gh release delete v[^`\s]+ --cleanup-tag/,
                 paragraph,
                 'recovery paragraph in health.md must name ' \
                 '`gh release delete ... --cleanup-tag` — the first command in ' \
                 "RELEASE.md's gem-less cleanup; got paragraph=#{paragraph.inspect}")

    assert_includes paragraph, 'git fetch --prune-tags',
                    'recovery paragraph in health.md must name ' \
                    '`git fetch --prune-tags` — the second command in RELEASE.md\'s ' \
                    "gem-less cleanup; got paragraph=#{paragraph.inspect}"

    refute_match(/never\b[^.!?]*workflow_dispatch/i,
                 paragraph,
                 'recovery paragraph in health.md must not forbid the ' \
                 '`workflow_dispatch` retry RELEASE.md prescribes for a release run ' \
                 "that failed after the bump was merged; got paragraph=#{paragraph.inspect}")

    refute_match(/never\b[^.!?]*break-glass/i,
                 paragraph,
                 'recovery paragraph in health.md must not forbid the break-glass ' \
                 'hand create RELEASE.md prescribes when CI is unavailable; ' \
                 "got paragraph=#{paragraph.inspect}")
  end

  private :assert_recovery_paragraph

  def test_release_run_that_published_nothing_is_a_named_no_op
    # release.yml:80-90 emits proceed=false when the version is already on
    # RubyGems and gates `release` on it; `demo` needs both
    # (release.yml:222-228). A skipped job does not fail a run, so this run
    # concludes `success` having published nothing — and `--json conclusion`
    # alone reports exactly that green as the last release published.
    out, err, status = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'skipped', demo: 'skipped'),
                                conclusion: 'success', sha: SHA_NOOP)

    assert_predicate status, :success?,
                     "row 9's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 1, lines.size,
                 "row 9 must print one line naming the no-op; got #{lines.inspect}"

    assert_match(/\Ano-op #{SHA_NOOP}\b/, lines.first,
                 'a proceed=false run must be named as a no-op carrying its headSha, so ' \
                 "the ask can link the run; got #{lines.inspect}")

    refute_includes out, "success #{SHA_NOOP}",
                    'a run that published nothing is NOT a green publish — printing ' \
                    "`success #{SHA_NOOP}` is the false green this row must not emit " \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    'proceed=false means nothing was owed, so this is not Unhealthy'
  end

  # A green run only counts as a PUBLICATION when RubyGems serves the version:
  # the probe answers 200 here (the run_command default), so this is the
  # healthy verdict - and the 404 and unreadable-probe shapes below are what
  # keep it honest.
  def test_release_run_that_published_grades_on_conclusion
    out, err, status = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'success', demo: 'success'),
                                conclusion: 'success', sha: SHA_PUBLISHED)

    assert_predicate status, :success?,
                     "row 9's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["success #{SHA_PUBLISHED} #{URL_RELEASE}"], out.lines.map(&:chomp),
                 'a run that really pushed the gem and cut the tag is an ordinary ' \
                 'publish: grade on conclusion and print `success <sha> <url>`'

    refute_includes out, 'no-op',
                    'the no-op signature is release SKIPPED; a release that ran is not one'
  end

  def test_unreadable_release_jobs_list_never_grades_success
    out, err, _status = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'skipped', demo: 'skipped'),
                                 conclusion: 'success', sha: SHA_PUBLISHED, jobs_fail: true)

    refute_includes out, "success #{SHA_PUBLISHED}",
                    'the `gh api .../jobs` stub failed, so the row cannot tell a ' \
                    'publish from a proceed=false no-op and must not print a green; ' \
                    "got stdout=#{out.inspect}, stderr=#{err.inspect}"

    assert_includes out, 'verdict unknown',
                    'an unreadable jobs list must fail closed as `verdict unknown`; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, SHA_PUBLISHED,
                    '`verdict unknown` must still name the sha it could not grade; ' \
                    "got stdout=#{out.inspect}"
  end

  def test_release_run_still_in_flight_is_not_graded
    # An executing run reports conclusion=null and a half-built job list: the
    # no-op signature would be a guess about jobs that have not concluded.
    out, err, status = run_row9(jobs: release_jobs_json(preflight: 'success', release: nil, demo: nil),
                                conclusion: 'null', sha: SHA_INFLIGHT)

    assert_predicate status, :success?,
                     "row 9's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["in flight #{SHA_INFLIGHT} #{URL_RELEASE}"], out.lines.map(&:chomp),
                 'a run with a null conclusion has not finished; report it in flight ' \
                 "and grade nothing (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    'still running is not a red release'
    refute_includes out, "success #{SHA_INFLIGHT}",
                    'a run that has not concluded cannot be a green publish'
  end

  def test_failed_preflight_is_not_read_as_a_no_op
    # A primary main push can fail preflight (for example on a probe error).
    # Its skipped dependents do not make that failure a proceed=false no-op.
    out, err, status = run_row9(jobs: release_jobs_json(preflight: 'failure', release: 'skipped', demo: 'skipped'),
                                conclusion: 'failure', sha: SHA_REFUSED)

    assert_predicate status, :success?,
                     "row 9's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["failure #{SHA_REFUSED} #{URL_RELEASE}"], out.lines.map(&:chomp),
                 'a failed primary release published nothing and was red; it grades on its ' \
                 "own conclusion, not as a no-op (stdout=#{out.inspect})"

    refute_includes out, 'no-op',
                    'proceed=false requires preflight itself to have succeeded'
  end

  # Row 9's own rule, unchanged: the release run list is read with the
  # `if type == "array" and length > 0` guard, so an empty list leaves the
  # sha empty and the row grades `verdict unknown` — it never grades a
  # colour off a list with no run in it. Pinned here so the empty outcome
  # stays `verdict unknown` on this row and is never filed as Unhealthy,
  # and so rows 8, 12 and 13 naming theirs `no run:` stays a difference
  # between the rows rather than a regression in row 9.
  def test_row9_empty_release_run_list_grades_verdict_unknown
    out, err, status = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'skipped', demo: 'skipped'),
                                conclusion: 'success', sha: SHA_NOOP, runs: :empty)

    assert_predicate status, :success?,
                     "row 9's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 1, lines.size,
                 "an empty release run list prints exactly one line; got #{lines.inspect}"

    assert_includes lines.first, 'verdict unknown',
                    'row 9 reads its release run list with the array-length guard, so an ' \
                    "empty list grades `verdict unknown` (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    'an empty run list is not a red release: no run exists to grade, so ' \
                    "nothing failed (stdout=#{out.inspect})"

    refute_includes out, 'no-op',
                    'an empty run list is not the proceed=false no-op signature either — ' \
                    "there is no run at all (stdout=#{out.inspect})"
  end

  # The release row grades a PUBLICATION, not a workflow run. release.yml
  # concludes `success` on a proceed=false no-op, and a green run whose
  # version never reached RubyGems is the same false green from the other
  # side. The run the row grades is bound to the commit that carries
  # Wurk::VERSION, so a run for another sha is refused rather than graded.
  def test_primary_release_selection_ignores_newer_dispatches_and_requires_both_filters
    primary = { headBranch: 'main', event: 'push', headSha: SHA_PUBLISHED,
                databaseId: 201, conclusion: 'success', url: URL_RELEASE }
    rejected_url = "#{URL_RELEASE}0"
    retry_url = "#{URL_RELEASE}1"
    off_main_url = "#{URL_RELEASE}2"
    off_main = primary.merge(headBranch: 'topic', event: 'workflow_dispatch',
                             conclusion: 'failure', url: rejected_url)
    main_retry = primary.merge(event: 'workflow_dispatch', conclusion: 'failure', url: retry_url)
    # The off-main push isolates the branch filter from the event filter.
    off_main_push = off_main.merge(event: 'push', url: off_main_url)
    jobs = release_jobs_json(preflight: 'success', release: 'success', demo: 'success')
    cell = command_cell('the last release published')
    out, err, status = run_row9(jobs: jobs, conclusion: 'success', sha: SHA_PUBLISHED,
                                runs: [off_main, main_retry, off_main_push, primary])

    assert_predicate status, :success?, err
    assert_equal "success #{SHA_PUBLISHED} #{URL_RELEASE}\n", out

    ['--branch main ', '--event push '].each do |filter|
      mutated = cell.sub(filter, '')

      refute_equal cell, mutated
      out, err, status = run_row9(jobs: jobs, conclusion: 'success', sha: SHA_PUBLISHED,
                                  runs: [off_main, main_retry, off_main_push, primary], cell: mutated)

      assert_predicate status, :success?, err
      selected_url = filter == '--branch main ' ? off_main_url : retry_url

      assert_equal "failure #{SHA_PUBLISHED} #{selected_url}\n", out,
                   "removing #{filter} must expose the wrong run"
    end
  end

  def test_rejected_dispatch_does_not_displace_an_inflight_or_absent_primary_release
    primary = { headBranch: 'main', event: 'push', headSha: SHA_PUBLISHED,
                databaseId: 201, conclusion: nil, url: URL_RELEASE }
    rejected_url = "#{URL_RELEASE}0"
    rejected = primary.merge(headBranch: 'topic', event: 'workflow_dispatch',
                             conclusion: 'failure', url: rejected_url)
    jobs = release_jobs_json(preflight: 'failure', release: 'skipped', demo: 'skipped')

    [[rejected, primary], [rejected]].each do |runs|
      out, err, status = run_row9(jobs: jobs, conclusion: 'failure', sha: SHA_PUBLISHED, runs: runs)

      assert_predicate status, :success?, err
      if runs.length == 2
        assert_equal "in flight #{SHA_PUBLISHED} #{URL_RELEASE}\n", out
      else
        assert_includes out, 'verdict unknown'
      end

      refute_includes out, rejected_url
      refute_includes out, 'failure'
      refute_includes out, 'Unhealthy'
    end
  end

  def test_brief_distinguishes_supported_main_retries_from_rejected_dispatches
    assert_includes @text, 'Supported main-branch workflow_dispatch retries'
    assert_includes @text, 'valid hand-dispatched retries, not primary main-push publication attempts'
    assert_includes @text, 'off-main rejection alone must not trigger a publication alarm'
    assert_includes @text, 'recovery remains filing-only'
  end

  def test_release_run_for_another_sha_is_refused
    out, err, status = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'success', demo: 'success'),
                                conclusion: 'success', sha: SHA_PUBLISHED,
                                version_sha: SHA_OTHER)

    assert_predicate status, :success?,
                     "row 9's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'verdict unknown',
                    'a release.yml run whose headSha is not the commit that carries ' \
                    "Wurk::VERSION says nothing about this version's release; got stdout=#{out.inspect}"

    refute_includes out, "success #{SHA_PUBLISHED}",
                    'a run for another commit cannot be graded as a publication of ' \
                    "this version (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    'two reads that disagree establish nothing, so this is neither ' \
                    "green nor red (stdout=#{out.inspect})"
  end

  def test_green_release_run_without_the_gem_is_unhealthy
    out, err, status = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'success', demo: 'success'),
                                conclusion: 'success', sha: SHA_PUBLISHED, http_status: '404')

    assert_predicate status, :success?,
                     "row 9's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Unhealthy',
                    'a green release run whose version RubyGems does not serve is a ' \
                    'false green: the gem was never published; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, 'green but empty publication',
                    'the verdict must name the defect it found; ' \
                    "got stdout=#{out.inspect}"

    refute_includes out, "success #{SHA_PUBLISHED}",
                    'a green workflow run is not a publication on its own; ' \
                    "got stdout=#{out.inspect}"
  end

  def test_green_release_run_with_an_unreadable_probe_is_unknown
    out, _err, _status = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'success', demo: 'success'),
                                  conclusion: 'success', sha: SHA_PUBLISHED, http_status: '000')

    assert_includes out, 'verdict unknown',
                    'a transport failure carries no HTTP status, so the row cannot ' \
                    "call the run a publication (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    'an unreadable probe is not evidence the version is absent; ' \
                    "got stdout=#{out.inspect}"

    refute_includes out, "success #{SHA_PUBLISHED}",
                    'an unreadable probe must not print a green; ' \
                    "got stdout=#{out.inspect}"
  end

  # The version a release row grades is read from the version-carrying
  # commit, never from the checkout's own copy of lib/wurk/version.rb. The
  # stale checkout here is the failure's exact shape: main bumped after the
  # checkout, so the row binds the run to the NEWER version's commit while
  # the working tree still carries 1.0.0. The fixtures put 9.9.9 at that
  # commit and STUB_CURL answers 200 only for 9.9.9 — a row that grepped the
  # checkout's copy would probe 1.0.0, get a 404, and print `Unhealthy:
  # green but empty publication` instead of this green.
  def test_release_row_grades_the_version_at_the_commit_not_the_checkouts_copy
    out, err, status = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'success', demo: 'success'),
                                conclusion: 'success', sha: SHA_PUBLISHED,
                                stale_version: '1.0.0')

    assert_predicate status, :success?,
                     "row 9's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["success #{SHA_PUBLISHED} #{URL_RELEASE}"], out.lines.map(&:chomp),
                 'the green run is graded through the version AT THE COMMIT (9.9.9), ' \
                 'not through the stale checkout\'s own VERSION, which RubyGems need ' \
                 "not serve; got stdout=#{out.inspect}"
  end

  # The version read fails closed like every other read in the row: with the
  # contents call unreadable there is no version to bind the run to, so
  # nothing may be graded.
  def test_version_unreadable_at_the_commit_fails_closed
    out, err, _status = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'success', demo: 'success'),
                                 conclusion: 'success', sha: SHA_PUBLISHED,
                                 version_at_head: nil)

    refute_includes out, "success #{SHA_PUBLISHED}",
                    'without a readable version at the commit the run cannot be ' \
                    'certified as a publication; ' \
                    "got stdout=#{out.inspect}, stderr=#{err.inspect}"

    refute_includes out, 'Unhealthy',
                    'an unreadable version is not evidence the release failed; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, 'verdict unknown',
                    'the row must fail closed when the version at the commit cannot ' \
                    "be read; got stdout=#{out.inspect}"
  end

  # Mutation guard for the stub itself: row 9's binding is the --commit
  # filter, and a stub that answered a release.yml run list WITHOUT it would
  # serve the fixture run to a row that dropped the filter — every verdict
  # test above would keep passing with the binding gone. Strip the filter
  # and run the mutated cell: the stub must refuse the request, and the row
  # must fail closed instead of grading the run green.
  def test_stub_refuses_a_release_run_list_without_the_commit_filter
    cell = command_cell('the last release published')
    mutated = cell.sub('--commit "$vsha" ', '')

    refute_equal cell, mutated, 'the mutation must actually remove the --commit filter'

    out, err, _status = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'success', demo: 'success'),
                                 conclusion: 'success', sha: SHA_PUBLISHED, cell: mutated)

    refute_includes out, "success #{SHA_PUBLISHED}",
                    'a release.yml run list without --commit is the newest run of any ' \
                    'shape and must never be graded; ' \
                    "got stdout=#{out.inspect}, stderr=#{err.inspect}"

    assert_includes out, 'verdict unknown',
                    'the row must fail closed when the stub refuses the unbound run ' \
                    "list; got stdout=#{out.inspect}"
  end

  # RELEASE.md's gem-less discriminator: an author of developerz-ai[bot] OR
  # zero assets is a GitHub Release with no gem behind it - the shape that
  # left seven stray releases standing as `Latest` while `gem install wurk`
  # kept serving the previous version.
  def test_gem_less_latest_release_is_unhealthy
    out, err, status = run_row_release_artifact(author: 'developerz-ai[bot]', assets: [])

    assert_predicate status, :success?,
                     "row 11's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Unhealthy',
                    'a Latest Release cut by developerz-ai[bot] with no gem behind it ' \
                    "is the gem-less release RELEASE.md describes; got stdout=#{out.inspect}"

    assert_includes out, 'gem-less',
                    'the verdict must name the defect it found; ' \
                    "got stdout=#{out.inspect}"

    refute_includes out, 'verdict unknown',
                    'a readable release lookup is a verdict, not an unknown'
  end

  def test_latest_release_without_the_gem_asset_is_unhealthy
    out, _err, status = run_row_release_artifact(author: 'github-actions[bot]', assets: [])

    assert_predicate status, :success?,
                     "row 11's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'Unhealthy',
                    'zero assets is a gem-less release whoever cut it; ' \
                    "got stdout=#{out.inspect}"
  end

  def test_latest_release_carrying_the_gem_is_healthy
    out, _err, status = run_row_release_artifact(author: 'github-actions[bot]',
                                                 assets: [{ 'name' => 'wurk-1.9.0.gem' }])

    assert_predicate status, :success?,
                     "row 11's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'success',
                    'a Latest Release with the gem attached and a real author is the ' \
                    "healthy verdict; got stdout=#{out.inspect}"

    refute_includes out, 'Unhealthy', 'a release carrying the gem is not Unhealthy'
    refute_includes out, 'verdict unknown', 'a readable release lookup is a verdict'
  end

  def test_unreadable_release_lookup_is_unknown
    out, _err, _status = run_row_release_artifact(release: nil)

    assert_includes out, 'verdict unknown',
                    'an unreadable release lookup cannot tell a gem-less Latest ' \
                    "Release from a real one, so it fails closed (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    'an unreadable lookup is not evidence of a gem-less release; ' \
                    "got stdout=#{out.inspect}"

    refute_includes out, 'success',
                    'an unreadable lookup must not print a healthy verdict; ' \
                    "got stdout=#{out.inspect}"
  end

  def test_demo_deploy_grades_on_conclusion_when_the_step_log_names_the_tag
    out, err, status = run_row12(jobs: demo_jobs_json,
                                 log: resolve_log(short: DEMO_TAG),
                                 conclusion: 'success', sha: SHA_DEMO)

    assert_predicate status, :success?,
                     "row 12's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["success #{SHA_DEMO} #{URL_DEMO} tagged #{DEMO_TAG}"], out.lines.map(&:chomp),
                 'a run whose `resolve built commit` step wrote the sha-<7> tag ' \
                 'Image Updater selects is an ordinary deploy: grade on conclusion ' \
                 "and name the tag; got stdout=#{out.inspect}"

    refute_includes out, 'Unhealthy',
                    'a readable tag means the deploy produced a candidate'
    refute_includes out, 'verdict unknown',
                    'a readable jobs list is a verdict, not an unknown'
  end

  def test_failed_demo_deploy_with_a_resolved_tag_still_files_a_failed_deploy_ask
    out, err, status = run_row12(jobs: demo_jobs_json,
                                 log: resolve_log(short: DEMO_TAG),
                                 conclusion: 'failure', sha: SHA_DEMO)

    assert_predicate status, :success?,
                     "row 12's command must run cleanly (stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["failure #{SHA_DEMO} #{URL_DEMO} tagged #{DEMO_TAG}"], out.lines.map(&:chomp),
                 'a failed deploy-demo run prints its own conclusion beside the sha, the ' \
                 'run url and the tag it pushed; the tag never rewrites the conclusion'

    refute_includes out, 'success', 'a resolved image tag cannot turn a failed run green'

    para = filing_paragraph.gsub(/\s+/, ' ')

    assert_includes para,
                    'row 12 files `demo deploy failed` for a failed deploy-demo conclusion line, ' \
                    'even when it includes `tagged sha-<7>`; the tag cannot override failure',
                    'the filing paragraph must give the failed deploy-demo conclusion line its ' \
                    'own stable title, tag or no tag'

    assert_includes para,
                    '`demo frozen: no sha-<7> image tag` only for the missing-tag verdict',
                    'the missing-tag title belongs to the missing-tag verdict alone, so a ' \
                    'failed deploy that pushed a tag files the failed-deploy title'
  end

  def test_green_demo_deploy_without_a_resolvable_tag_is_unhealthy
    # deploy-demo.yml:7-11 only BUILDS and PUSHES. Infra's Image Updater selects
    # the newest tag matching ^sha-[0-9a-f]{7}$; a green run that wrote no such
    # tag leaves the demo on its old digest and says nothing. That is how it
    # silently went stale across several releases (deploy-demo.yml:165-172).
    out, err, status = run_row12(jobs: demo_jobs_json,
                                 log: resolve_log(short: nil),
                                 conclusion: 'success', sha: SHA_DEMO_FROZEN)

    assert_predicate status, :success?,
                     "row 12's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Unhealthy',
                    'a green run with no sha-[0-9a-f]{7} tag in `resolve built ' \
                    'commit` gives Image Updater no candidate — Unhealthy; got ' \
                    "stdout=#{out.inspect}"

    refute_includes out, "success #{SHA_DEMO_FROZEN}",
                    'an unresolvable tag is NOT a green deploy: printing `success ' \
                    '<sha>` is the false green this row must not emit ' \
                    "(stdout=#{out.inspect})"

    assert_includes out, SHA_DEMO_FROZEN,
                    'the Unhealthy verdict must surface the headSha so the ask ' \
                    "can link the run; got stdout=#{out.inspect}"
  end

  def test_a_tag_from_another_step_does_not_buy_this_row_a_green
    # The row reads the whole `build` job log, and a docker build is full of
    # `sha-<7>`-shaped strings that are not tags at all. Only the
    # `resolve built commit` step's own output is evidence for this row, so a
    # token over in `verify pushed tags resolve` must leave the run Unhealthy:
    # the tag this step never wrote gives Image Updater no candidate either.
    out, err, status = run_row12(jobs: demo_jobs_json,
                                 log: resolve_log(short: nil, decoys: { VERIFY_STEP => [DECOY_REF] }),
                                 conclusion: 'success', sha: SHA_DEMO_FROZEN)

    assert_predicate status, :success?,
                     "row 12's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    refute_includes out, "success #{SHA_DEMO_FROZEN}",
                    'the only sha-<7> in the log belongs to another step, so this ' \
                    'step resolved nothing; a green printed off it is the false ' \
                    "green this row must not emit (stdout=#{out.inspect})"

    refute_includes out, 'tagged sha-1234567',
                    'a tag `resolve built commit` never wrote must never be named ' \
                    "as the tag it resolved (stdout=#{out.inspect})"

    assert_includes out, 'Unhealthy',
                    'with nothing resolved in the named step the demo has no ' \
                    "Image Updater candidate; got stdout=#{out.inspect}"
  end

  def test_eight_hex_tag_is_not_the_short_sha_tag_image_updater_selects
    # `sha-12345678` is the 8-hex full-sha shape: it does NOT match Image
    # Updater's ^sha-[0-9a-f]{7}$, so a match that takes the first seven
    # characters and stops prints a green naming a tag nothing can ever select —
    # the demo stays frozen while the row certifies it.
    out, err, status = run_row12(jobs: demo_jobs_json,
                                 log: resolve_log(short: 'sha-12345678'),
                                 conclusion: 'success', sha: SHA_DEMO_FROZEN)

    assert_predicate status, :success?,
                     "row 12's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    refute_includes out, "success #{SHA_DEMO_FROZEN}",
                    "a tag Image Updater's ^sha-[0-9a-f]{7}$ cannot select leaves " \
                    'the demo frozen, so it is not a green deploy; got ' \
                    "stdout=#{out.inspect}"

    refute_includes out, 'tagged sha-1234567',
                    'the 8-hex tag must not pass by matching its first seven ' \
                    "characters; got stdout=#{out.inspect}"

    assert_includes out, 'Unhealthy',
                    "got stdout=#{out.inspect}"
  end

  # The row's step filter, this file's fixture and `gh`'s own layout are one
  # convention, and only the last of the three is real: shaped
  # `<timestamp>\t<job>\t<step>\t<message>`, the fixture agreed with a row that
  # filtered field 3, every other test in this file stayed green, and the row
  # running against an actual log kept no line at all — grading a correctly
  # tagged deploy Unhealthy. So pin the layout `gh run view --log` really emits
  # (job, step, then the log line's own `<timestamp> <message>`) and require the
  # row's awk to read the step out of THAT column.
  def test_row12_reads_the_step_out_of_the_column_gh_prints
    fields = log_lines(RESOLVE_STEP, ['short=sha-7777777']).first.split("\t")

    assert_equal 3, fields.size,
                 '`gh run view --log` prints `<job>\t<step>\t<timestamp> <message>`, ' \
                 "three columns; got #{fields.inspect}"

    assert_equal 'build', fields[0],
                 'the job name comes first; got ' \
                 "#{fields.inspect}"

    assert_equal RESOLVE_STEP, fields[1],
                 'the step name is the second column, the one row 12 filters; got ' \
                 "#{fields.inspect}"

    assert_match(/\A\d{4}-\d{2}-\d{2}T[\d:.]+Z \S/, fields[2],
                 "the log line's timestamp and message share the last column; got " \
                 "#{fields.inspect}")

    cell = command_cell('the demo deployed')
    field = cell[/[$](\d) == "?resolve built commit"?/, 1]

    refute_nil field,
               'row 12 must select the resolve step\'s own lines out of the job log; ' \
               "got #{cell.inspect}"

    assert_equal '2', field,
                 'the row must read field 2, the column `gh` prints the step in: ' \
                 'any other column keeps no real log line, so a deploy that wrote its ' \
                 'tag is graded Unhealthy'
  end

  def test_unreadable_demo_jobs_list_never_grades_success
    out, err, _status = run_row12(jobs: demo_jobs_json,
                                  log: resolve_log(short: DEMO_TAG),
                                  conclusion: 'success', sha: SHA_DEMO, jobs_fail: true)

    refute_includes out, "success #{SHA_DEMO}",
                    'the `gh api .../jobs` stub failed, so the row cannot see the ' \
                    '`resolve built commit` step and must not fall through to ' \
                    'grading on conclusion; ' \
                    "got stdout=#{out.inspect}, stderr=#{err.inspect}"

    assert_includes out, 'verdict unknown',
                    'an unreadable jobs list must fail closed as `verdict unknown`; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, SHA_DEMO,
                    '`verdict unknown` must still name the sha it could not grade, ' \
                    "so the next checkup can re-run it; got stdout=#{out.inspect}"
  end

  def test_unreadable_demo_log_never_grades_success
    # Row 12 reads the `build` job log separately (`gh run view ... --job ... --log`)
    # because step logs are not carried on the jobs API. If that read fails — a
    # rate-limit, a 4xx, or a 5xx — the jobs list is fine but the tag is unknowable,
    # so the row must fail closed exactly the way an unreadable jobs list does:
    # `verdict unknown <sha>`, never `success <sha>`.
    out, err, _status = run_row12(jobs: demo_jobs_json,
                                  log: resolve_log(short: DEMO_TAG),
                                  conclusion: 'success', sha: SHA_DEMO, log_fail: true)

    refute_includes out, "success #{SHA_DEMO}",
                    'the `gh run view --log` stub failed, so the row cannot see the ' \
                    '`sha-<7>` tag and must not fall through to grading on conclusion; ' \
                    "got stdout=#{out.inspect}, stderr=#{err.inspect}"

    refute_includes out, "tagged #{DEMO_TAG}",
                    'an unreadable log cannot read a tag — printing `tagged ' \
                    "#{DEMO_TAG}` would be lying about a tag the row did not read; " \
                    "got stdout=#{out.inspect}"

    assert_includes out, 'verdict unknown',
                    'an unreadable log must fail closed as `verdict unknown`, the ' \
                    'same fail-closed rule an unreadable jobs list uses; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, SHA_DEMO,
                    '`verdict unknown` must still name the sha it could not grade, ' \
                    "so the next checkup can re-run it; got stdout=#{out.inspect}"
  end

  # Row 12 grades the run list before it grades anything else, so an empty
  # list is named rather than extracted: the old `jq -c '.[0]'` read turned
  # `[]` into the literal string `null` for every field, and the row fell
  # into the same `verdict unknown null null` catch-all a failed read fell
  # into.
  def test_row12_empty_run_list_is_a_named_no_run_outcome
    out, err, status = run_row12(jobs: demo_jobs_json,
                                 log: resolve_log(short: DEMO_TAG),
                                 conclusion: 'success', sha: SHA_DEMO, runs: :empty)

    assert_predicate status, :success?,
                     "row 12's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 1, lines.size,
                 "an empty run list prints exactly one line; got #{lines.inspect}"

    assert_match(/\Ano run: deploy-demo\.yml has no matching run\z/, lines.first,
                 'a readable but empty run list is its own outcome: the row names it ' \
                 "and the workflow it asked about; got #{lines.inspect}")

    refute_includes out, 'verdict unknown',
                    'an empty run list is a READABLE answer, not an unreadable one — ' \
                    "the two findings must never look alike (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    'no run exists to grade, so nothing failed; the empty outcome is not ' \
                    "a red one and files no ask (stdout=#{out.inspect})"

    refute_includes out, 'null',
                    'the empty outcome carries no sha and no url — there is no run to ' \
                    'link, and a literal `null` field is the defect this replaces ' \
                    "(stdout=#{out.inspect})"
  end

  # The unreadable arm of the same rule for row 12: a run list the row
  # could not read establishes nothing, so it fails closed as
  # `verdict unknown` and says the list was NOT READABLE. It is a different
  # finding from the readable-empty outcome above and must not look like it.
  def test_row12_unreadable_run_list_grades_verdict_unknown_not_readable
    out, err, status = run_row12(jobs: demo_jobs_json,
                                 log: resolve_log(short: DEMO_TAG),
                                 conclusion: 'success', sha: SHA_DEMO, runs: :fail)

    assert_predicate status, :success?,
                     "row 12's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 1, lines.size,
                 "an unreadable run list prints exactly one line; got #{lines.inspect}"

    assert_includes lines.first, 'verdict unknown',
                    'a run list the row could not read establishes nothing, so it fails ' \
                    "closed as `verdict unknown` (stdout=#{out.inspect})"

    assert_includes lines.first, 'not readable',
                    'the line must also say the list was NOT READABLE: an unreadable ' \
                    'list and an empty one are different findings and must never look ' \
                    "alike (stdout=#{out.inspect})"

    assert_includes lines.first, 'deploy-demo.yml',
                    'the line must name the workflow it could not read a run list for; ' \
                    "got #{lines.first.inspect}"

    refute_includes out, 'Unhealthy',
                    'an unreadable list is not evidence that the run failed; ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'null',
                    'an unreadable list has no run to carry a sha or a url; ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, "success #{SHA_DEMO}",
                    'a run list the row could not read cannot certify a green deploy; ' \
                    "(stdout=#{out.inspect})"
  end

  # The half-failed read for row 12: gh exits non-zero after emitting the list,
  # so the row must grade the read `verdict unknown` off the EXIT STATUS — not
  # print the named `no run:` outcome for the failed empty one, and not grade
  # the emitted run's conclusion and tag.
  def test_row12_nonzero_exit_with_json_stdout_is_unreadable_not_graded
    out, err, status = run_row12(jobs: demo_jobs_json,
                                 log: resolve_log(short: DEMO_TAG),
                                 conclusion: 'success', sha: SHA_DEMO, runs: 'error-empty')

    assert_predicate status, :success?,
                     "row 12's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 1, lines.size,
                 "a half-failed read prints exactly one line; got #{lines.inspect}"

    assert_includes lines.first, 'verdict unknown',
                    'gh exited non-zero after emitting the list, so the read FAILED and the ' \
                    "row must fail closed (stdout=#{out.inspect})"

    assert_includes lines.first, 'not readable',
                    "the line must say the list was not readable (stdout=#{out.inspect})"

    assert_includes lines.first, 'deploy-demo.yml',
                    'the line must name the workflow it could not read a run list for; ' \
                    "got #{lines.first.inspect}"

    refute_includes out, 'no run:',
                    'a read that exited non-zero is not a readable empty list: printing the ' \
                    'named `no run:` outcome for it contradicts the failed-read contract ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    "a failed read is not evidence that the deploy failed (stdout=#{out.inspect})"

    out, err, status = run_row12(jobs: demo_jobs_json,
                                 log: resolve_log(short: DEMO_TAG),
                                 conclusion: 'success', sha: SHA_DEMO, runs: 'error-run')

    assert_predicate status, :success?,
                     "row 12's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'verdict unknown',
                    'gh exited non-zero after emitting the run, so nothing may be graded off ' \
                    "its bytes (stdout=#{out.inspect})"

    refute_includes out, "success #{SHA_DEMO}",
                    'a half-failed read cannot certify a green deploy ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, "tagged #{DEMO_TAG}",
                    'the emitted bytes are disowned by their failed read, so the tag must not ' \
                    "be read off them (stdout=#{out.inspect})"
  end

  def test_demo_block_scopes_green_to_the_pushed_tag_and_names_the_served_probe
    # Row 12 proves a pushed image tag, not a served version. The brief must
    # say so and point at the separate served-version probe, whose endpoint is
    # public and read-only.
    block = demo_block

    assert_includes block, 'api_controller.rb:53',
                    'the served-version prose must name the anchor that ' \
                    "produces the demo's `version:`; got #{block.inspect}"

    assert_includes block, 'wurk.demo.developerz.ai/wurk/api/meta',
                    'the served-version prose must name the endpoint the probe ' \
                    "reads; got #{block.inspect}"

    assert_match(/not sufficient/,
                 block,
                 'the block must say green is necessary, not sufficient, or the ' \
                 "reader takes a pushed tag as proof the demo is live; got #{block.inspect}")

    refute_match(/cannot reach/i, block,
                 'the brief must no longer claim the served version cannot be ' \
                 "probed; got #{block.inspect}")

    cited = File.readlines(API_CONTROLLER)

    assert_includes cited[52],
                    'version: ::Wurk::VERSION',
                    'api_controller.rb:53 must be where the demo reports its ' \
                    "version; it now reads #{cited[52].inspect}"
  end

  # ---- The demo served-version row -----------------------------------------
  #
  # This row answers a question row 12 cannot: what version does the PUBLIC,
  # unauthenticated demo actually serve? The command is RUN here against a
  # stubbed curl — a substring match over the brief would accept a guard that
  # never fires. Three mutually exclusive verdicts are pinned:
  #
  #   * a matching version -> healthy, naming the version;
  #   * a different version -> Unhealthy, naming served AND expected;
  #   * an unreadable probe -> `verdict unknown`, never green. Unreadable
  #     includes an HTTP 200 whose body is a matching version object
  #     followed by invalid text: jq parses a STREAM of JSON values, emits
  #     the version, and only then fails on the trailing garbage — so the
  #     row must check jq's exit status and validate the body as one single
  #     JSON object before it grades anything.
  def test_demo_served_version_match_grades_success
    out, err, status = run_served_version_row(body: JSON.generate('version' => checkout_version))

    assert_predicate status, :success?,
                     "the served-version row must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'success',
                    'a served version equal to the checkout must grade healthy; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, checkout_version,
                    'the healthy verdict must name the version it found; ' \
                    "got stdout=#{out.inspect}"

    refute_includes out, 'Unhealthy', 'a matching version is not Unhealthy'
    refute_includes out, 'verdict unknown', 'a readable match is a verdict'
  end

  def test_demo_served_version_mismatch_grades_unhealthy_naming_both_versions
    served = '0.0.1'
    out, err, status = run_served_version_row(body: JSON.generate('version' => served))

    assert_predicate status, :success?,
                     "the served-version row must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Unhealthy',
                    'a served version different from the checkout must grade Unhealthy; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, served,
                    'the Unhealthy verdict must name the served version; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, checkout_version,
                    'the Unhealthy verdict must name the expected version; ' \
                    "got stdout=#{out.inspect}"

    refute_includes out, 'success',
                    "a mismatch is not a success; got stdout=#{out.inspect}"
    refute_includes out, 'verdict unknown',
                    'a readable mismatch is a verdict, not an unknown'
  end

  # The unreadable-probe cases. Every one of them must grade `verdict
  # unknown` — never green, never a mismatch. The non-200 cases carry a BODY
  # that would read as a perfectly good version: real `curl` without `-f`
  # exits 0 and prints the body for a 404 too, so a row that graded the body
  # alone would call these healthy. That is the shape the guard has to catch,
  # and it is why the stub prints the body on every status.
  def test_demo_served_version_unreadable_probe_grades_verdict_unknown
    [
      ['transport failure', nil, 7, 7],
      # A demo that accepts the connection but never finishes the response:
      # curl kills the request at its --max-time and exits 28 with no body
      # and no HTTP status. The same unreadable shape as any other transport
      # failure — and the reason the probe has to be bounded in time at all.
      ['response deadline exceeded', nil, 28, 28],
      ['non-200 response', JSON.generate('version' => checkout_version), 404, 0],
      ['non-200 response carrying a stale version', JSON.generate('version' => '0.0.1'), 503, 0],
      ['non-JSON body', '<html>not found</html>', 200, 0],
      ['JSON without a version key', JSON.generate('read_only' => true), 200, 0]
    ].each do |label, body, status_code, curl_exit|
      out, err, status = run_served_version_row(
        body: body,
        http_status: status_code,
        curl_exit: curl_exit
      )

      assert_predicate status, :success?,
                       "#{label}: the served-version row must run cleanly " \
                       "(status=#{status.inspect}, stdout=#{out.inspect}, stderr=#{err.inspect})"

      assert_includes out, 'verdict unknown',
                      "#{label}: an unavailable or unreadable probe must grade " \
                      "`verdict unknown`, never green; got stdout=#{out.inspect}"

      refute_includes out, 'success',
                      "#{label}: an unavailable probe is not healthy; got stdout=#{out.inspect}"
      refute_includes out, 'Unhealthy',
                      "#{label}: an unavailable probe is not evidence of a mismatch; " \
                      "got stdout=#{out.inspect}"
    end
  end

  # The false green jq's stream semantics can print: on a body shaped
  # `{"version":"<expected>"}<garbage>` jq emits the version FIRST and only
  # then fails to parse the trailing text, so a row that captures jq's stdout
  # and ignores its exit status grades that body a healthy success — on the
  # old command this fixture printed `success: the demo serves <version>`
  # while jq exited 5. The row must check jq's status and validate the body
  # as one single JSON object before grading.
  def test_matching_version_followed_by_trailing_garbage_is_not_a_success
    body = "#{JSON.generate('version' => checkout_version)} trailing garbage"
    out, err, status = run_served_version_row(body: body)

    assert_predicate status, :success?,
                     "the served-version row must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'verdict unknown',
                    'an HTTP 200 whose body is a matching version object followed by invalid ' \
                    'text is not a readable answer: jq fails to parse the trailing garbage ' \
                    'after emitting the version, so a green printed off that body is exactly ' \
                    "the false green this row must never print; got stdout=#{out.inspect}"

    refute_includes out, 'success',
                    'trailing garbage after the version object must not buy the row a success ' \
                    "verdict (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    'an unparseable body is not evidence of a mismatch either; ' \
                    "got stdout=#{out.inspect}"
  end

  # The probes must be bounded in TIME. The checkup runs unattended: a curl
  # without a total deadline never returns when the server accepts the
  # connection but stalls the response — the row prints no verdict and every
  # signal after it goes unread. All three rows whose command leaves `gh` for
  # curl (row 9's publication cross-check, row 10's availability probe, row
  # 13's demo probe) must bound the whole request with `--max-time`; the
  # runtime half of the property — curl exit 28 grades `verdict unknown` — is
  # pinned by running the demo row against the stubbed curl above.
  def test_probe_curls_carry_a_total_deadline
    [command_cell('the last release published'),
     command_cell('RubyGems serves `Wurk::VERSION`', gh_command: 'gh api'),
     served_version_command].each do |cell|
      # An invocation — always `$(curl …` in these rows — not a prose mention
      # of curl inside an echo string (`... failed (curl rc=$rc ...)`).
      invocations = cell.scan(/\$\(curl [^;|)]*/).map { |match| match.delete_prefix('$(') }

      refute_empty invocations,
                   "#{cell.inspect} must probe with curl for this guard to mean anything"

      invocations.each do |invocation|
        seconds = invocation[/--max-time (\d+)/, 1].to_i

        assert_operator seconds, :>, 0,
                        'every probe curl must bound the WHOLE request with --max-time: an ' \
                        'unbounded curl never returns when the server accepts the connection ' \
                        'but stalls the response, so the scheduled checkup blocks without ' \
                        'printing a verdict and the signals after it never run; got ' \
                        "#{invocation.inspect}"
      end
    end
  end

  # Row 15 grades dependabot PRs against per-ecosystem budgets. The brief
  # derives each budget from dependabot.yml's own `schedule.interval` and
  # bundler's `cooldown.default-days`, plus a 7-day margin: 28d bundler
  # (7 weekly + 14 cooldown + 7), 14d bun (7+0+7), 37d github-actions
  # (30+0+7), 37d docker (30+0+7). A PR whose statusCheckRollup — the LIST of
  # CheckRun/StatusContext entries `gh` emits, rolled up as health.md's step 3
  # reads it — grades FAILURE, and whose age in days is strictly greater than
  # its budget, IS stuck; a red rollup younger than its budget is not (the
  # docker case in dependabot.yml:63-72 is the headline example); SUCCESS or
  # PENDING is never stuck. The fixtures are CLI-shaped on purpose: shaped
  # `{"state": ...}` they agreed with a rollup read off the PR that `gh` never
  # sends, so these tests passed while the row reported nothing at all.
  def test_monthly_ecosystem_pr_aged_under_budget_is_not_stuck
    # github-actions: 30-day-old PR with a failed check run. Budget is 37d
    # (monthly interval + 7d margin). 30 < 37, so it is red but young, and
    # MUST NOT be reported stuck.
    now = Time.now.utc
    pr = {
      'number' => 7001,
      'title' => 'Bump actions/checkout from 4 to 5 in /',
      'createdAt' => (now - (30 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    refute_includes out, 'Dependabot is stuck on #7001',
                    'a github-actions PR aged 30d is under its 37d budget ' \
                    '(dependabot.yml:54-61) even when FAILURE — the row must not ' \
                    "name it stuck (stdout=#{out.inspect})"
    refute_includes out, 'Dependabot is stuck',
                    'no PR was past budget AND FAILURE — nothing is stuck ' \
                    "(stdout=#{out.inspect})"
    refute_includes out, 'Unhealthy',
                    'no PR passed its budget and FAILURE — nothing is Unhealthy ' \
                    "(stdout=#{out.inspect})"
  end

  def test_red_docker_pr_under_budget_waiting_on_bun_pins_is_not_stuck
    # dependabot.yml:63-72: docker bumps the Dockerfile's oven/bun tag but
    # cannot edit the bun-version: inputs in test.yml/release.yml nor bun in
    # mise.toml, so test/unit/toolchain_pins_test.rb (lines 11, 84-90) keeps
    # the PR red until a human (or the maintainer agent) pushes matching pin
    # edits. The PR is FAILURE and only 5 days old; budget is 37d. A row
    # that names this stuck would file a false-positive ask on the
    # expected-red state.
    now = Time.now.utc
    pr = {
      'number' => 7102,
      'title' => 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
      'createdAt' => (now - (5 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    refute_includes out, 'Dependabot is stuck on #7102',
                    'a red docker PR aged 5d is exactly the expected-red shape of ' \
                    "dependabot.yml:63-72; it must NOT print the PR number (stdout=#{out.inspect})"
    refute_includes out, 'Unhealthy',
                    'an expected-red PR is the headline of dependabot.yml:63-72, not a ' \
                    "regression the row should file (stdout=#{out.inspect})"

    refute_includes out, 'is waiting on us',
                    'waiting-on-us requires the age to be strictly PAST the budget: a 5d red ' \
                    'docker PR prints neither verdict — not stuck, and not waiting on us ' \
                    "(stdout=#{out.inspect})"
  end

  def test_past_budget_red_docker_bump_with_a_bun_pin_title_is_waiting_on_us
    # dependabot.yml:63-74: the docker bump moves the Dockerfile's oven/bun
    # FROM, but the four matching bun pins (bun-version: in test.yml and
    # release.yml, bun in mise.toml, the oven/bun FROM in docs/deployment.md)
    # are sites dependabot cannot edit, so toolchain_pins_test.rb keeps the PR
    # red until the maintainer agent pushes the pin edits to the branch. Past
    # the 37d budget that is not author-inactivity for dependabot to fix — it
    # is waiting on US — and the row must say so instead of printing stuck.
    pr = dependabot_pr(number: 7701, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'Unhealthy: Docker bump #7701 is waiting on us',
                    'a 40d red docker PR whose title matches the bun-pin shape is waiting on ' \
                    "us, not stuck (stdout=#{out.inspect})"

    assert_includes out, 'push the pin edits to the branch',
                    'the waiting verdict must name the next action — the maintainer agent ' \
                    "pushes the matching pin edits to the dependabot branch (stdout=#{out.inspect})"

    assert_includes out, '(age 40d > 37d budget for docker)',
                    'the waiting line must carry the age and the docker budget, so a reader ' \
                    "can see WHY without re-running the command (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7701',
                    'the waiting classification must SUPPRESS the stuck line for the same PR: ' \
                    'one verdict per PR, and this PR is not author-inactivity ' \
                    "(stdout=#{out.inspect})"
  end

  def test_past_budget_red_docker_bump_without_a_matching_title_is_stuck
    # The waiting predicate needs the title shape as well as the age and the
    # red rollup: `Bump ruby from 3.4.1 to 3.4.2 in /` names a dependency with
    # no slash in it and no group, so nothing about the PR is waiting on us —
    # dependabot could fix a red ruby bump itself. Past budget and red, it is
    # genuinely stuck.
    pr = dependabot_pr(number: 7702, title: 'Bump ruby from 3.4.1 to 3.4.2 in /',
                       branch: 'dependabot/docker/ruby', age_days: 40, sha: SHA_DOCKER)
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    stuck = out.lines.map(&:chomp).select { |line| line.start_with?('Unhealthy:') }

    assert_equal 1, stuck.size,
                 "one stuck PR prints one Unhealthy line; got #{out.lines.inspect}"

    assert_match(/\AUnhealthy: Dependabot is stuck on #7702\b/, stuck.first,
                 'a red docker PR past its budget whose title matches neither bun-pin shape ' \
                 "is genuinely stuck; got #{stuck.first.inspect}")

    assert_match(/\(age 40d > 37d budget for docker\)\z/, stuck.first,
                 'the stuck line still carries the age and the docker budget; ' \
                 "got #{stuck.first.inspect}")

    refute_includes out, 'is waiting on us',
                    'a non-bun-pin docker PR must not classify waiting-on-us; ' \
                    "(stdout=#{out.inspect})"
  end

  def test_a_grouped_docker_bump_is_waiting_on_us
    # The docker ecosystem is grouped (dependabot.yml:83-87), and dependabot
    # titles the group PR after the ecosystem: `Bump the docker group with N
    # updates`. That title matches the ` group with .* updates$` waiting
    # shape, so a 40d red grouped docker bump classifies waiting-on-us exactly
    # like the `oven/bun` form.
    pr = dependabot_pr(number: 7703, title: 'Bump the docker group with 2 updates',
                       branch: 'dependabot/docker/minor-and-patch', age_days: 40, sha: SHA_DOCKER)
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'Unhealthy: Docker bump #7703 is waiting on us',
                    'the grouped title matches the second bun-pin shape, so the PR classifies ' \
                    "waiting-on-us; got stdout=#{out.inspect}"

    refute_includes out, 'Dependabot is stuck on #7703',
                    'a waiting-on-us PR never prints the stuck line ' \
                    "(stdout=#{out.inspect})"
  end

  # THE regression fixture for the waiting predicate: the pin edits have
  # already been pushed — every bun pin at the head agrees with the Dockerfile
  # bump — but another check still fails, so the PR is red past its budget.
  # Graded on the title shape alone it printed `push the pin edits` forever
  # and suppressed the stuck verdict indefinitely; the row now reads the five
  # pin sites at headRefOid, sees agreement, and lets step 5 grade it stuck.
  def test_pins_already_pushed_but_ci_still_red_grades_stuck_not_waiting
    pr = dependabot_pr(number: 7704, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)
    out, _err, status = run_row15(prs: [pr], pins: :agree)

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    stuck = out.lines.map(&:chomp).select { |line| line.start_with?('Unhealthy:') }

    assert_equal 1, stuck.size,
                 "one stuck PR prints one Unhealthy line; got #{out.lines.inspect}"

    assert_match(/\AUnhealthy: Dependabot is stuck on #7704 \(age 40d > 37d budget for docker\)\z/,
                 stuck.first,
                 'a red past-budget docker PR whose head pins agree is NOT waiting on us — the ' \
                 'pin edits are pushed, so the ask must be the stuck one; ' \
                 "got #{stuck.first.inspect}")

    refute_includes out, 'is waiting on us',
                    'waiting-on-us requires a VERIFIED outstanding pin mismatch; a head whose ' \
                    'pins agree must never print it ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'push the pin edits',
                    'an instruction the branch already satisfies must never be printed: the pin ' \
                    "edits are on the branch and something else is red (stdout=#{out.inspect})"
  end

  # The verification is over EVERY pin site: one workflow still carrying the
  # old bun-version fails the pins check exactly as hard as the site
  # dependabot moved, and the agent can still fix it — the PR is waiting on
  # us. A row that compared only the Dockerfile against mise.toml would read
  # this head as agreeing and file author-inactivity against dependabot.
  def test_one_stale_pin_site_is_still_an_outstanding_mismatch
    pr = dependabot_pr(number: 7705, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)
    out, _err, status = run_row15(
      prs: [pr],
      pins: { 'Dockerfile' => BUN_NEW, 'mise.toml' => BUN_NEW, 'docs/deployment.md' => BUN_NEW,
              '.github/workflows/test.yml' => BUN_OLD, '.github/workflows/release.yml' => BUN_NEW }
    )

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'Unhealthy: Docker bump #7705 is waiting on us',
                    'one stale pin site is an outstanding mismatch — the row must classify the ' \
                    "PR waiting-on-us, not stuck (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7705',
                    'a PR the agent can still unblock by pushing the missing pin is not ' \
                    "author-inactivity (stdout=#{out.inspect})"
  end

  # A pin-site read that fails verifies nothing, and a verdict the row cannot
  # establish is never a colour: neither waiting-on-us (the classification
  # that suppresses stuck indefinitely) nor stuck (author-inactivity on
  # unreadable evidence) may be printed for that PR. The row names the read
  # that failed and files no ask; the next checkup re-reads it.
  def test_unreadable_head_pins_file_no_ask_and_print_verdict_unknown
    pr = dependabot_pr(number: 7706, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)
    out, _err, status = run_row15(prs: [pr], pins: nil)

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    unknown = out.lines.map(&:chomp).select { |line| line.include?('verdict unknown') }

    assert_equal 1, unknown.size,
                 "the unreadable pin read prints one verdict-unknown line; got #{out.lines.inspect}"

    assert_includes unknown.first, 'not readable',
                    'the line must say the pins were NOT readable, the same fail-closed shape ' \
                    "the unreadable-list outcome uses; got #{unknown.first.inspect}"

    assert_includes unknown.first, '#7706',
                    "the line must name the PR it could not grade; got #{unknown.first.inspect}"

    assert_includes unknown.first, SHA_DOCKER,
                    "the line must carry the head sha it could not read at; got #{unknown.first.inspect}"

    refute_includes out, 'Unhealthy',
                    "an unreadable pin read is no evidence for either verdict (stdout=#{out.inspect})"

    refute_includes out, 'is waiting on us',
                    'claiming waiting-on-us on an unreadable read is exactly the defect this ' \
                    "pins (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7706',
                    "stuck on an unreadable read files author-inactivity on no evidence (stdout=#{out.inspect})"
  end

  # The failure a real contents 404 or rate limit produces carries BYTES:
  # `gh api` emits its nonempty JSON error body on stdout and exits
  # non-zero. A row that guarded the captured strings alone passed that
  # body as a successful read, parsed no pin out of it, and graded the
  # failed read an outstanding mismatch — the false `waiting on us` ask.
  # Each site's exit status is captured beside its bytes and graded first,
  # so the failed read names `verdict unknown ... not readable`, exactly
  # like the empty-body failure above, and files no ask.
  def test_pin_reads_failing_with_a_nonempty_error_body_are_not_graded_as_a_mismatch
    pr = dependabot_pr(number: 7709, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)
    out, _err, status = run_row15(prs: [pr], pins: :error_body)

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    unknown = out.lines.map(&:chomp).select { |line| line.include?('verdict unknown') }

    assert_equal 1, unknown.size,
                 "the error-body pin read prints one verdict-unknown line; got #{out.lines.inspect}"

    assert_includes unknown.first, 'not readable',
                    'the line must say the pins were NOT readable — a read that exited non-zero ' \
                    "is a failed read whatever bytes it left behind; got #{unknown.first.inspect}"

    assert_includes unknown.first, '#7709',
                    "the line must name the PR it could not grade; got #{unknown.first.inspect}"

    assert_includes unknown.first, SHA_DOCKER,
                    "the line must carry the head sha it could not read at; got #{unknown.first.inspect}"

    refute_includes out, 'Unhealthy',
                    'a failed read with a nonempty error body is no evidence for either verdict ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'is waiting on us',
                    'grading the error body as a read files exactly the false waiting-on-us ask ' \
                    "this pins shut (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7709',
                    "a failed read files no ask in the other direction either (stdout=#{out.inspect})"
  end

  # ONE site 404ing with a nonempty error body while the other four still
  # parse is the sharper shape: the pins are still genuinely mismatched, so
  # a row that graded the bytes it did read — or checked only the first
  # call's status — would read this head as an outstanding mismatch. Every
  # site's exit status has to fail the read before anything is parsed.
  def test_one_pin_site_failing_with_an_error_body_is_not_graded_as_a_mismatch
    pr = dependabot_pr(number: 7710, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)
    out, _err, status = run_row15(prs: [pr], pins: { 'mise.toml' => :error })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    unknown = out.lines.map(&:chomp).select { |line| line.include?('verdict unknown') }

    assert_equal 1, unknown.size,
                 "the single-site error-body read prints one verdict-unknown line; got #{out.lines.inspect}"

    assert_includes unknown.first, '#7710',
                    "the line must name the PR whose pin read failed; got #{unknown.first.inspect}"

    refute_includes out, 'Unhealthy',
                    'one failed read spoils the verification whatever the other four parsed ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'is waiting on us',
                    'the pins really are mismatched here, but the verification is over a failed ' \
                    "read — a verdict built on it is the false waiting-on-us ask (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7710',
                    "a failed read files no ask (stdout=#{out.inspect})"
  end

  # The pins are read AT THE HEAD (headRefOid — the only field a head SHA is
  # ever read from): a candidate the list carries no head for cannot anchor
  # the read, so it grades the same unreadable way instead of guessing.
  def test_a_candidate_without_a_head_sha_cannot_be_graded_waiting
    pr = dependabot_pr(number: 7707, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40)
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'verdict unknown',
                    'no head sha means no anchored pin read, so the row fails closed ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    "neither verdict is printable without the head the read anchors to (stdout=#{out.inspect})"
  end

  # The stub refuses a pin read whose ref is not the PR's own head — the same
  # commitment the release stub makes about `--commit`. A row that graded the
  # pins at any other tree (main, a base branch) would read the pins as they
  # were BEFORE the pin edits landed and classify a fixed PR waiting-on-us
  # forever. Mutate the cell to read at main: the read must fail closed.
  def test_stub_refuses_a_pin_read_that_is_not_head_bound
    cell = command_cell('Dependabot is not stuck', gh_command: 'gh pr list')
    mutated = cell.sub('contents/$1?ref=$2', 'contents/$1?ref=main')

    refute_equal cell, mutated, 'the mutation must actually unbind the pin read from the head sha'

    pr = dependabot_pr(number: 7708, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)
    out, _err, status = run_row15(prs: [pr], pins: :agree, cell: mutated)

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'verdict unknown',
                    'a pin read at the wrong ref is a failed read: the row must fail closed, ' \
                    "not grade the mutated tree (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    "a failed read is no evidence for either verdict (stdout=#{out.inspect})"
  end

  # The graded step must document the verification it performs: the
  # head-anchored pin read, the agreeing-pins-fall-through-to-stuck rule, and
  # the no-ask rule for a read that failed. A brief that classified
  # waiting-on-us on the title shape alone would re-arm the
  # indefinite-suppression defect the runtime fixtures above pin.
  def test_waiting_step_documents_the_head_pin_verification
    step = waiting_step

    assert_includes step, 'headRefOid',
                    'step 6 must name the field the pin read is anchored to'

    assert_match(/agree/, step,
                 'step 6 must say what agreeing pins grade — stuck per step 5, not waiting-on-us')

    assert_includes step, 'verdict unknown',
                    'step 6 must name the outcome of a pin read that fails'

    assert_match(/files no ask|no ask filed/, step,
                 'step 6 must say the unreadable-pins PR files no ask')

    assert_includes step, 'suppresses the stuck verdict indefinitely',
                    'step 6 must name the defect the verification exists for'

    assert_match(/exit status/i, step,
                 'step 6 must say the failed read is graded off the exit status: gh api can emit ' \
                 'a nonempty JSON error body and exit non-zero, which an empty-string guard alone ' \
                 'reads as a successful read')

    assert_includes step, 'nonempty JSON error body',
                    'step 6 must name the shape that makes the exit status load-bearing — the ' \
                    'error body is nonempty, so grading the captured bytes alone parses the error ' \
                    'JSON and reads the failed read as a pin mismatch'
  end

  # The docker pin carve-out: a PAST-BUDGET docker PR whose only red check is
  # the toolchain-pins assertion is the expected-red shape of dependabot.yml:
  # 63-72 — dependabot bumps the Dockerfile's oven/bun tag and cannot edit the
  # matching pins elsewhere, so the pins assertion stays red until the pin
  # edits land. It is not a stuck PR. The discriminator needs a second read:
  # `statusCheckRollup` carries job-level names only, and the pins assertion
  # runs inside the same `test + coverage (latest ruby/rails)` job as every
  # other Ruby failure, so the rollup alone cannot tell this from an unrelated
  # failure. The second read is the failing CI JOB's own log — `gh run view
  # <id> --job <job id> --log-failed` — and the discriminator is the failing
  # test FILE it names. The run's SIBLING jobs are clean here (`parity:,
  # lint:` success): the pins assertion must be the run's ONLY red check for
  # the carve-out to fire at all.
  def test_past_budget_docker_pr_whose_only_red_check_is_the_pins_assertion_is_awaiting_pin_edits
    pr = dependabot_pr(number: 7701, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)

    pins_log = failed_run_log(
      'Failure: test_every_bun_pin_names_the_same_version [test/unit/toolchain_pins_test.rb:73]:'
    )
    out, err, status = run_row15(prs: [pr], parity: 'success', lint: 'success',
                                 runs: { SHA_DOCKER => pins_log })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Dependabot #7701 is awaiting matching pin edits',
                    'a past-budget docker PR whose only red check is the ' \
                    'toolchain-pins assertion is awaiting matching pin edits, not ' \
                    "stuck (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7701',
                    'the carve-out must print NO stuck line for the expected-red ' \
                    "docker shape (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    "the expected-red docker PR files no ask (stdout=#{out.inspect})"
  end

  # The carve-out names ONE expected-red shape and swallows nothing else: a
  # docker PR with any other red check still grades as stuck, with the same
  # line shape as every other stuck PR.
  def test_past_budget_docker_pr_with_any_other_red_check_is_still_stuck
    pr = dependabot_pr(number: 7702, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)

    out, err, status = run_row15(prs: [pr], runs: { SHA_DOCKER => failed_run_log(
      'Failure: test_something_else [test/unit/some_other_test.rb:12]:'
    ) })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_match(/\AUnhealthy: Dependabot is stuck on #7702 \(age 40d > 37d budget for docker\)\z/,
                 out.lines.map(&:chomp).find { |line| line.start_with?('Unhealthy:') }.to_s,
                 'a docker PR with any OTHER red check keeps the stuck verdict ' \
                 "(stdout=#{out.inspect})")

    refute_includes out, 'awaiting matching pin edits',
                    'the pin carve-out must not swallow an unrelated failure ' \
                    "(stdout=#{out.inspect})"
  end

  # A READABLE failed log that names NO test file is unreadable evidence, not
  # a green one: the row cannot tell the pins assertion from any other
  # failure, so it fails closed as `verdict unknown` — never stuck (it has no
  # evidence of an unrelated failure) and never the pin-edit verdict (it has
  # no evidence of the pins assertion either).
  def test_past_budget_docker_pr_whose_failed_log_names_no_test_file_fails_closed
    pr = dependabot_pr(number: 7710, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)

    out, err, status = run_row15(prs: [pr], runs: { SHA_DOCKER => failed_run_log(
      'Error: the workflow could not start: the job was cancelled before any test ran'
    ) })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'verdict unknown',
                    'a readable failed log that names no test file is unreadable ' \
                    "evidence and must fail closed (stdout=#{out.inspect})"

    refute_includes out, 'awaiting matching pin edits',
                    'no failing test file named means no evidence of the pins ' \
                    "assertion — the carve-out must not fire (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7710',
                    'no failing test file named means no evidence of an unrelated ' \
                    "failure either — the row must not guess stuck (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    "an unreadable discriminator read files no ask (stdout=#{out.inspect})"
  end

  # The carve-out fires only when the pins assertion is the run's ONLY red
  # check. This fixture keeps the job-bound log pins-only but marks `parity
  # (oracle)` FAILED in the run's job list: a second red check the rollup
  # already counts, which the row must NOT swallow into the pin-edit
  # verdict — the PR keeps the stuck verdict and files the Unhealthy ask.
  def test_past_budget_docker_pr_with_a_failed_parity_job_is_still_stuck
    pr = dependabot_pr(number: 7711, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)

    out, err, status = run_row15(prs: [pr], parity: 'failure', runs: { SHA_DOCKER => failed_run_log(
      'Failure: test_every_bun_pin_names_the_same_version [test/unit/toolchain_pins_test.rb:73]:'
    ) })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Unhealthy: Dependabot is stuck on #7711',
                    'a failed `parity (oracle)` job is a second red check the ' \
                    'carve-out must not swallow — the PR keeps the stuck verdict ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'awaiting matching pin edits',
                    'a sibling job\'s failure must not clear the PR ' \
                    "(stdout=#{out.inspect})"
  end

  # The sibling read is not parity-specific: ANY other red check in the run —
  # `lint (rubocop)` here — keeps the stuck verdict, with the job-bound log
  # still naming only the pins assertion.
  def test_past_budget_docker_pr_with_a_failed_lint_job_is_still_stuck
    pr = dependabot_pr(number: 7707, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)

    out, err, status = run_row15(prs: [pr], lint: 'failure', runs: { SHA_DOCKER => failed_run_log(
      'Failure: test_every_bun_pin_names_the_same_version [test/unit/toolchain_pins_test.rb:73]:'
    ) })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Unhealthy: Dependabot is stuck on #7707',
                    'a failed `lint (rubocop)` job is a second red check the ' \
                    'carve-out must not swallow — the PR keeps the stuck verdict ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'awaiting matching pin edits',
                    "a red sibling job must not clear the PR (stdout=#{out.inspect})"
  end

  # `sib` inspects only the SELECTED test.yml run's own jobs. `bench.yml` and
  # `topology.yml` also fire on `pull_request`, so their checks sit in the
  # SAME statusCheckRollup — and a failed `bench vs base` job is a red entry
  # the selected run's own job list can never account for. The carve-out is
  # therefore granted only when EVERY red rollup entry names a FAILED job of
  # the selected run: a pins-only test.yml failure beside a failed bench.yml
  # or topology.yml check keeps the stuck verdict. The names are real check
  # names: bench.yml names its job `bench vs base`, topology.yml's `topology`
  # job takes its key as the check name.
  def test_past_budget_docker_pr_with_a_failed_check_outside_the_selected_run_is_still_stuck
    pins_log = failed_run_log(
      'Failure: test_every_bun_pin_names_the_same_version [test/unit/toolchain_pins_test.rb:73]:'
    )

    [['bench vs base', 'bench'], ['topology', 'topology.yml']].each do |outside, wf|
      pr = dependabot_pr(number: 7716, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                         branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER,
                         rollup: [check_run('FAILURE'),
                                  check_run('FAILURE', name: outside, workflow: wf)])
      out, err, status = run_row15(prs: [pr], runs: { SHA_DOCKER => pins_log })

      assert_predicate status, :success?,
                       "#{wf}: row 15's command must run cleanly (status=#{status.inspect}, " \
                       "stdout=#{out.inspect}, stderr=#{err.inspect})"

      assert_includes out, 'Unhealthy: Dependabot is stuck on #7716',
                      "a failed #{outside} check is a red entry outside the selected test.yml " \
                      'run — the carve-out must not swallow it and the PR keeps the stuck ' \
                      "verdict (stdout=#{out.inspect})"

      refute_includes out, 'awaiting matching pin edits',
                      'a red entry the selected run does not account for must not clear the PR; ' \
                      "got stdout=#{out.inspect}"
    end
  end

  # The other half of the union: a red StatusContext names no run at all, so
  # the selected run's failed jobs can never account for it. Same verdict as
  # a cross-workflow check failure — the carve-out does not fire.
  def test_past_budget_docker_pr_with_a_red_non_actions_status_is_still_stuck
    pr = dependabot_pr(number: 7717, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER,
                       rollup: [check_run('FAILURE'), status_context('ERROR')])

    out, err, status = run_row15(prs: [pr], runs: { SHA_DOCKER => failed_run_log(
      'Failure: test_every_bun_pin_names_the_same_version [test/unit/toolchain_pins_test.rb:73]:'
    ) })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Unhealthy: Dependabot is stuck on #7717',
                    'a red non-Actions status names no run, so the selected run cannot ' \
                    "account for it and the PR keeps the stuck verdict (stdout=#{out.inspect})"

    refute_includes out, 'awaiting matching pin edits',
                    'a red entry outside the selected run must not clear the PR; ' \
                    "got stdout=#{out.inspect}"
  end

  # The counterweight: only RED entries outside the selected run block the
  # carve-out. A green `bench vs base` check beside the pins-only failure is
  # still exactly the expected-red shape the carve-out exists for, and a
  # cross-check that read every entry instead of the red ones would file a
  # stuck ask on it.
  def test_a_green_check_outside_the_selected_run_does_not_block_the_carve_out
    pr = dependabot_pr(number: 7718, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER,
                       rollup: [check_run('FAILURE'),
                                check_run('SUCCESS', name: 'bench vs base', workflow: 'bench')])

    out, err, status = run_row15(prs: [pr], runs: { SHA_DOCKER => failed_run_log(
      'Failure: test_every_bun_pin_names_the_same_version [test/unit/toolchain_pins_test.rb:73]:'
    ) })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Dependabot #7718 is awaiting matching pin edits',
                    'a green check outside the selected run decides nothing — the pins-only ' \
                    'failure is the expected-red shape and the carve-out fires ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7718',
                    "a green outside check must not grade the PR stuck (stdout=#{out.inspect})"
  end

  # The discriminator reads the `test + coverage (latest ruby/rails)` JOB's
  # failed log, not the run's. A docker PR also runs `parity (oracle)`
  # (test.yml:381-419) and `lint (rubocop)`, and a run-level `--log-failed`
  # mixes every failed job of the run into one log — so the stub serves the
  # two logs separately, with the aggregate naming a DIFFERENT test file.
  # The sibling jobs are clean here, so the job-bound read clears the PR and
  # a brief that dropped the --job binding reads the aggregate and grades
  # this pins-only PR STUCK — the binding stays falsifiable instead of
  # merely documented.
  def test_the_docker_pin_discriminator_reads_the_test_coverage_job_not_the_whole_run
    pr = dependabot_pr(number: 7708, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)

    pins_log = failed_run_log(
      'Failure: test_every_bun_pin_names_the_same_version [test/unit/toolchain_pins_test.rb:73]:'
    )
    out, err, status = run_row15(prs: [pr], parity: 'success', lint: 'success',
                                 runs: { SHA_DOCKER => pins_log })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Dependabot #7708 is awaiting matching pin edits',
                    'the pins assertion failed inside the `test + coverage ' \
                    '(latest ruby/rails)` job and no sibling job went red, so ' \
                    "the carve-out fires (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7708',
                    'with clean siblings the carve-out fires and no stuck line ' \
                    "is printed (stdout=#{out.inspect})"
  end

  # The discriminator\'s run read is bound to the CI workflow. `bench.yml` and
  # `topology.yml` also fire on `pull_request`, so an unfiltered read takes
  # the FIRST failed run for the commit across all of them — a run whose
  # failed output names no Ruby test file, which can never clear the
  # carve-out. The stub refuses the unbound request, so the row fails closed.
  def test_stub_refuses_a_discriminator_read_without_the_ci_workflow
    cell = command_cell('Dependabot is not stuck', gh_command: 'gh pr list')
    mutated = cell.sub('gh run list --workflow test.yml --commit "$sha"', 'gh run list --commit "$sha"')

    refute_equal cell, mutated, 'the mutation must actually drop the --workflow filter'

    pr = dependabot_pr(number: 7712, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)

    out, err, _status = run_row15(prs: [pr], runs: { SHA_DOCKER => failed_run_log(
      'Failure: test_every_bun_pin_names_the_same_version [test/unit/toolchain_pins_test.rb:73]:'
    ) }, cell: mutated)

    assert_includes out, 'verdict unknown',
                    'a discriminator read that is not bound to the CI workflow is ' \
                    'not the read the row depends on, and the stub refuses it ' \
                    "(stdout=#{out.inspect}, stderr=#{err.inspect})"

    refute_includes out, 'Dependabot is stuck on #7712',
                    "a refused read cannot have produced a stuck verdict (stdout=#{out.inspect})"

    refute_includes out, 'awaiting matching pin edits',
                    "a refused read cannot have cleared the PR (stdout=#{out.inspect})"
  end

  # The run's JOB LIST is the second of the three reads. An unreadable one
  # leaves the row with no job to read the failing output from, so it fails
  # closed as `verdict unknown` — never stuck, never cleared.
  def test_an_unreadable_docker_job_list_fails_closed
    pr = dependabot_pr(number: 7713, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)

    out, err, status = run_row15(prs: [pr], jobs_fail: true, runs: { SHA_DOCKER => failed_run_log(
      'Failure: test_every_bun_pin_names_the_same_version [test/unit/toolchain_pins_test.rb:73]:'
    ) })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'verdict unknown',
                    'an unreadable job list leaves no job to read the failing ' \
                    "output from, so the row must fail closed (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7713',
                    "an unreadable job list cannot have produced a stuck verdict (stdout=#{out.inspect})"

    refute_includes out, 'awaiting matching pin edits',
                    "an unreadable job list cannot have cleared the PR (stdout=#{out.inspect})"
  end

  # The discriminator read fails CLOSED. An unreadable read is neither a
  # stuck verdict nor a cleared one: it grades `verdict unknown`, never
  # `Unhealthy` and never the pin-edit verdict.
  def test_unreadable_docker_pin_discriminator_fails_closed
    pr = dependabot_pr(number: 7703, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)

    out, err, status = run_row15(prs: [pr], runs: { SHA_DOCKER => nil })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'verdict unknown',
                    'an unreadable discriminator read must fail closed as ' \
                    "`verdict unknown` (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7703',
                    'an unreadable discriminator read must never guess a stuck ' \
                    "verdict (stdout=#{out.inspect})"

    refute_includes out, 'awaiting matching pin edits',
                    'an unreadable discriminator read must never guess the ' \
                    "pin-edit verdict (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    "an unreadable discriminator read files no ask (stdout=#{out.inspect})"
  end

  # Mutation guard for the stub itself: the discriminator read is bound to the
  # PR's head commit (`gh run list --workflow test.yml --commit <sha>`), and a
  # stub that answered it without the commit would serve one PR's failing run
  # to another. The read is refused instead, so a brief that dropped or
  # narrowed it fails closed.
  def test_stub_refuses_a_discriminator_read_without_the_head_commit
    cell = command_cell('Dependabot is not stuck', gh_command: 'gh pr list')
    mutated = cell.sub('gh run list --workflow test.yml --commit "$sha"', 'gh run list --workflow test.yml')

    refute_equal cell, mutated, 'the mutation must actually drop the --commit filter'

    pr = dependabot_pr(number: 7704, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)

    out, err, _status = run_row15(prs: [pr], runs: { SHA_DOCKER => failed_run_log(
      'Failure: test_every_bun_pin_names_the_same_version [test/unit/toolchain_pins_test.rb:73]:'
    ) }, cell: mutated)

    assert_includes out, 'verdict unknown',
                    'a discriminator read without the head commit is not the read ' \
                    'the row depends on, and the stub refuses it ' \
                    "(stdout=#{out.inspect}, stderr=#{err.inspect})"

    refute_includes out, 'Dependabot is stuck on #7704',
                    "a refused read cannot have produced a stuck verdict (stdout=#{out.inspect})"

    refute_includes out, 'awaiting matching pin edits',
                    "a refused read cannot have cleared the PR (stdout=#{out.inspect})"
  end

  # The discriminator is read PER PR, not once for the whole list: two docker
  # PRs must not share one verdict. Here the first PR failed only the pins
  # assertion and the second failed something else; each PR is graded off its
  # OWN failing run and its OWN job log.
  def test_the_docker_pin_discriminator_is_read_per_pr
    pins_only = dependabot_pr(number: 7705, title: 'Bump oven/bun from 1.4.1 to 1.4.2 in /',
                              branch: 'dependabot/docker/oven/bun', age_days: 40, sha: SHA_DOCKER)
    other = dependabot_pr(number: 7706, title: 'Bump ruby:3.4-slim-bookworm from 3.4 to 3.5 in /',
                          branch: 'dependabot/docker/ruby', age_days: 40, sha: SHA_PR)

    pins_log = failed_run_log(
      'Failure: test_every_bun_pin_names_the_same_version ' \
      '[test/unit/toolchain_pins_test.rb:73]:'
    )

    out, err, status = run_row15(prs: [pins_only, other], runs: {
                                   SHA_DOCKER => pins_log,
                                   SHA_PR => failed_run_log(
                                     'Failure: test_something_else [test/unit/some_other_test.rb:12]:'
                                   )
                                 })

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Dependabot #7705 is awaiting matching pin edits',
                    'the PR whose own failing run names only the pins assertion is ' \
                    "awaiting pin edits (stdout=#{out.inspect})"

    assert_includes out, 'Unhealthy: Dependabot is stuck on #7706',
                    "the other PR keeps the stuck verdict (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on #7705',
                    'one PR\'s failing run must not grade another PR ' \
                    "(stdout=#{out.inspect})"
  end

  # The brief has to DOCUMENT the discriminator, not just run it: a reader
  # must be able to see WHICH read decides the carve-out, that it fails
  # closed, and that the carve-out is a description of expected red CI and
  # never permission to merge or to bypass a gate. It must also point at the
  # platform lane's stalled-PR sweep instead of adding a second one.
  def test_the_docker_pin_carve_out_prose_names_its_read_and_its_limits
    para = dependabot_grading_block

    assert_includes para, 'gh run list --workflow test.yml --commit',
                    'the prose must name the read that binds the discriminator to ' \
                    'the PR\'s own head commit AND to the CI workflow that runs ' \
                    "the pins assertion; got #{para.inspect}"

    assert_includes para, 'gh run view',
                    'the prose must name the read that carries the failing check\'s ' \
                    "own output; got #{para.inspect}"

    assert_includes para, '--log-failed',
                    'the prose must name the failed-output read the discriminator ' \
                    "depends on; got #{para.inspect}"

    assert_includes para, '--job',
                    'the prose must name the JOB the failed output is read from — ' \
                    'a run-level read mixes every failed job of the run into one ' \
                    "log; got #{para.inspect}"

    assert_includes para, 'test + coverage (latest ruby/rails)',
                    'the prose must name the job the pins assertion runs in — ' \
                    "the discriminator is bound to it; got #{para.inspect}"

    assert_includes para, 'test/unit/toolchain_pins_test.rb',
                    'the prose must name the assertion whose failure is the ' \
                    "expected-red shape; got #{para.inspect}"

    assert_includes para, 'FAILS CLOSED',
                    'the prose must say the discriminator fails closed; ' \
                    "got #{para.inspect}"

    assert_match(/never permission to merge/i, para,
                 'the carve-out describes expected red CI — it must never read as ' \
                 "permission to merge; got #{para.inspect}")

    assert_includes para, 'close_awaiting_author_after_days: 21',
                    'the prose must point at the platform lane\'s stalled-PR sweep ' \
                    "instead of adding a second one; got #{para.inspect}"

    assert_match(/no second age-based/i, para,
                 'the prose must say it adds no second age-based ping or close; ' \
                 "got #{para.inspect}")
  end

  # The brief has to DOCUMENT the rollup cross-check, not just run it: a
  # reader must see that every red statusCheckRollup entry has to name a
  # failed job of the selected run, that the bench.yml/topology.yml checks
  # are the failures `sib` never sees, and that those keep the stuck
  # verdict. Every assertion reads the step-5 bullet itself, so a phrase
  # sitting elsewhere in the brief cannot stand in for it.
  def test_the_docker_pin_carve_out_prose_names_the_rollup_cross_check
    step = docker_pin_carve_out_step

    assert_includes step, 'statusCheckRollup',
                    'the carve-out prose must name the rollup the cross-check reads; ' \
                    "got #{step.inspect}"

    assert_match(/EVERY red (rollup )?entry/i, step,
                 'the prose must state that every red rollup entry has to be accounted ' \
                 "for before the carve-out fires; got #{step.inspect}")

    assert_match(/names (one of those jobs|a failed job of the selected run)/, step,
                 'the prose must say what accounts for a red entry — a failed job of the ' \
                 "selected run; got #{step.inspect}")

    assert_includes step, 'bench.yml',
                    'the prose must name bench.yml, whose pull_request checks `sib` never sees; ' \
                    "got #{step.inspect}"

    assert_includes step, 'topology.yml',
                    'the prose must name topology.yml, whose pull_request checks `sib` never ' \
                    "sees; got #{step.inspect}"

    assert_match(/keeps the stuck verdict/, step,
                 'the prose must say a red entry outside the selected run keeps the stuck ' \
                 "verdict; got #{step.inspect}")
  end

  def test_pr_past_ecosystem_budget_and_red_is_reported_stuck
    # bundler: 35-day-old PR whose check run concluded FAILURE. Budget is 28d
    # (weekly interval + 14d cooldown + 7d margin, dependabot.yml:27-30). The
    # PR has run past its entire grace window — it IS stuck. The row must
    # print one `Unhealthy: Dependabot is stuck on #<n>` line naming the
    # number, so the ask can link the PR (cf. the RubyGems row's `Unhealthy:`
    # line, which names the missing version so the ask can link it).
    now = Time.now.utc
    pr = {
      'number' => 7203,
      'title' => 'Bump rubocop from 2.0.0 to 2.1.0 in /',
      'createdAt' => (now - (35 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    lines = out.lines.map(&:chomp)
    stuck = lines.select { |line| line.start_with?('Unhealthy: Dependabot is stuck on #7203') }

    assert_equal 1, stuck.size,
                 'one stuck PR prints one Unhealthy line — the row names per-PR, ' \
                 "not a summary (stdout=#{out.inspect})"

    assert_match(/\AUnhealthy: Dependabot is stuck on #7203\b/, stuck.first,
                 'the stuck line must name the signal and the PR number so the ask ' \
                 "can link it (got #{stuck.first.inspect})")

    assert_match(/\(age 35d > 28d budget for bundler\)\z/, stuck.first,
                 'the line must carry the age and the bundler budget, so a reader can ' \
                 "see WHY this is stuck without re-running the command (got #{stuck.first.inspect})")

    assert_includes lines, 'dependabot: 1 open PRs (bundler 1 FAILURE)',
                    'the row reports what it read — the ecosystem, how many of its ' \
                    'PRs are open and the state they rolled up to ' \
                    "(stdout=#{out.inspect})"

    assert(lines.any? { |line| line.start_with?('#7203 ') },
           'the row reports every open PR — number, ecosystem, branch, head sha ' \
           "and last update (stdout=#{out.inspect})")
  end

  def test_bun_pr_in_frontend_uses_the_bun_budget_not_bundlers
    # The ` in /frontend` elif is the only thing separating bun's 14d budget
    # from bundler's 28d: both titles end ` in /<dir>`, and a bun PR that fell
    # through to the bundler default would be under budget for another 14 days.
    # A 20d red bun PR is past bun's 14d (weekly + 7d margin,
    # dependabot.yml:41-49) and must therefore print stuck.
    now = Time.now.utc
    stuck = {
      'number' => 7304,
      'title' => 'Bump @types/node from 20.0.0 to 20.1.0 in /frontend',
      'createdAt' => (now - (20 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row15(prs: [stuck])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'budget for bun',
                    'a red PR titled `… in /frontend` must grade against bun\'s 14d ' \
                    'budget (dependabot.yml:41-49), NOT the 28d bundler default — ' \
                    "at 20d it is past bun's budget and must print stuck (stdout=#{out.inspect})"

    refute_includes out, 'budget for bundler',
                    'the title names /frontend, so this is a bun PR; grading it ' \
                    "bundler would hide it for another 14 days (stdout=#{out.inspect})"
  end

  def test_bun_pr_under_budget_is_not_stuck
    # The counterweight to the case above: the same bun title at 15d is past the
    # 14d budget and stuck, but at 5d it is red-and-young. This is the shape a
    # weekly ecosystem normally produces — most of the time it is under budget.
    now = Time.now.utc
    pr = {
      'number' => 7305,
      'title' => 'Bump @types/node from 20.0.0 to 20.1.0 in /frontend',
      'createdAt' => (now - (5 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    refute_includes out, 'Dependabot is stuck',
                    'a red bun PR aged 5d is under its 14d budget (dependabot.yml:41-49); ' \
                    "the row must not report it stuck (stdout=#{out.inspect})"

    assert_includes out, 'dependabot: 1 open PRs (bun 1 FAILURE)',
                    'the row still reports what it read — a red but young PR is a line ' \
                    "in the report, not a verdict (stdout=#{out.inspect})"
  end

  def test_github_actions_group_pr_uses_the_github_actions_budget
    # dependabot.yml:60-62 groups every action into one `actions` PR titled
    # `Bump the github-actions group with N updates` — not the per-action
    # `Bump actions/…` form the other test pins. Without the ` group with .*
    # updates$` pattern that title falls through to `bundler` (28d) instead of
    # `github-actions` (37d). At 40d it is past the correct 37d budget, so a
    # misclassification as bundler would silently hide it — this must print the
    # github-actions budget.
    now = Time.now.utc
    pr = {
      'number' => 7306,
      'title' => 'Bump the github-actions group with 4 updates',
      'createdAt' => (now - (40 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'budget for github-actions',
                    'the grouped `Bump the github-actions group with N updates` title ' \
                    "(dependabot.yml:60-62) must map to github-actions' 37d budget, " \
                    "not the 28d bundler default (stdout=#{out.inspect})"

    refute_includes out, 'budget for bundler',
                    'a grouped github-actions PR is not a bundler PR; grading it ' \
                    "bundler would apply the wrong budget (stdout=#{out.inspect})"
  end

  def test_past_budget_but_green_pr_is_not_stuck
    # the rollup rules' SUCCESS half: a PR past its budget whose checks all
    # concluded SUCCESS is not stuck — an old green is just an old
    # human-pending merge, not a regression dependabot can fix on its own.
    # This is the same 35d/28d bundler shape as the stuck test, differing
    # only in what the rollup grades.
    now = Time.now.utc
    pr = {
      'number' => 7307,
      'title' => 'Bump rubocop from 2.0.0 to 2.1.0 in /',
      'createdAt' => (now - (35 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('SUCCESS')]
    }
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    refute_includes out, 'Dependabot is stuck',
                    'a past-budget PR whose checks all concluded SUCCESS is an old green ' \
                    'pending merge, not stuck (health.md:103); the row must not report ' \
                    "it stuck (stdout=#{out.inspect})"

    assert_includes out, 'dependabot: 1 open PRs (bundler 1 SUCCESS)',
                    'the row still reports what it read — an old green is a line in the ' \
                    "report, not a verdict (stdout=#{out.inspect})"
  end

  def test_past_budget_but_pending_pr_is_not_stuck
    # the rollup rules' PENDING half: a rollup that is still PENDING is in flight,
    # so it is not stuck either. Same 35d/28d bundler shape, one check concluded
    # and one still running — Actions sends `conclusion: null` for a job in
    # progress. A rollup that is neither clean nor red must not be graded
    # FAILURE: that would file an ask on every dependabot PR whose CI happens
    # to be mid-run.
    now = Time.now.utc
    pr = {
      'number' => 7308,
      'title' => 'Bump rubocop from 2.0.0 to 2.1.0 in /',
      'createdAt' => (now - (35 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('SUCCESS'), running_check_run]
    }
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    refute_includes out, 'Dependabot is stuck',
                    'a past-budget PR with a check still running is in flight, not ' \
                    "stuck (health.md:103); the row must not report it stuck (stdout=#{out.inspect})"

    assert_includes out, 'dependabot: 1 open PRs (bundler 1 PENDING)',
                    'the row still reports what it read — a PR still in flight is a line ' \
                    "in the report, not a verdict (stdout=#{out.inspect})"
  end

  def test_one_failed_check_makes_the_whole_rollup_red
    # The shape a rollup read off the PR cannot grade at all: `gh` sends a LIST,
    # so the entries have to be rolled UP. A green job and a still-running job
    # alongside one failed commit status is a red PR, and it is 40d into
    # github-actions' 37d budget — it must print stuck. Reading
    # `.statusCheckRollup.state` instead of aggregating prints nothing here, and
    # that is the whole defect: the row reported no stuck PR, ever.
    now = Time.now.utc
    pr = {
      'number' => 7309,
      'title' => 'Bump the github-actions group with 4 updates',
      'createdAt' => (now - (40 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('SUCCESS'), running_check_run, status_context('FAILURE')]
    }
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    stuck = out.lines.map(&:chomp).select { |line| line.start_with?('Unhealthy:') }

    assert_equal 1, stuck.size,
                 "one stuck PR prints one Unhealthy line; got #{out.lines.inspect}"

    assert_match(/\AUnhealthy: Dependabot is stuck on #7309\b/, stuck.first,
                 'one failed entry makes the whole PR red, however green or ' \
                 "still-running the rest of the rollup is; got #{out.inspect}")

    assert_match(/\(age 40d > 37d budget for github-actions\)\z/, stuck.first,
                 'the ecosystem comes from the branch (or the title), never from the ' \
                 "rollup; got #{stuck.first.inspect}")
  end

  def test_a_timed_out_check_counts_as_a_failure
    # health.md's step-3 failure vocabulary: Actions reports nine CheckRun
    # conclusions and six of them block a merge as hard as FAILURE. A PR wedged
    # on a job that kept timing out is exactly the regression this row exists to
    # notice, so grading for the literal string "FAILURE" is not enough.
    now = Time.now.utc
    pr = {
      'number' => 7311,
      'title' => 'Bump rubocop from 2.0.0 to 2.1.0 in /',
      'createdAt' => (now - (35 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('SUCCESS'), check_run('TIMED_OUT')]
    }
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_match(/\AUnhealthy: Dependabot is stuck on #7311\b/,
                 out.lines.map(&:chomp).select { |line| line.start_with?('Unhealthy:') }.first.to_s,
                 'a TIMED_OUT check blocks a merge exactly as hard as FAILURE; ' \
                 "got #{out.inspect}")
  end

  def test_non_actions_status_context_failure_is_stuck
    # The other half of the union: a check from an app outside Actions carries
    # `state` and no conclusion at all. Reading conclusions alone grades this PR
    # SUCCESS and never reports it, so the rollup must read both entry types.
    now = Time.now.utc
    pr = {
      'number' => 7312,
      'title' => 'Bump rubocop from 2.0.0 to 2.1.0 in /',
      'createdAt' => (now - (35 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('SUCCESS'), status_context('ERROR')]
    }
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_match(/\(age 35d > 28d budget for bundler\)\z/,
                 out.lines.map(&:chomp).select { |line| line.start_with?('Unhealthy:') }.first.to_s,
                 'a StatusContext of ERROR is a failure too; got ' \
                 "#{out.inspect}")
  end

  def test_nothing_to_wait_on_is_not_a_failure
    # SKIPPED and NEUTRAL conclusions decide no merge, and a PR carrying no
    # checks at all — the empty rollup — has nothing red in it. Both are past
    # the budget; neither may print stuck.
    now = Time.now.utc
    rollups = [[check_run('SUCCESS'), check_run('SKIPPED')], []]

    rollups.each_with_index do |rollup, i|
      pr = {
        'number' => 7313 + i,
        'title' => 'Bump rubocop from 2.0.0 to 2.1.0 in /',
        'createdAt' => (now - (35 * 86_400)).iso8601,
        'statusCheckRollup' => rollup
      }
      out, _err, status = run_row15(prs: [pr])

      assert_predicate status, :success?,
                       "row 15's command must run cleanly (status=#{status.inspect})"

      refute_includes out, 'Dependabot is stuck',
                      "rollup #{rollup.inspect} has nothing red in it, so the row must " \
                      "not report it stuck at 35d (stdout=#{out.inspect})"
    end
  end

  def test_unreadable_dependabot_pr_list_fails_closed
    # If the stub cannot serve the open-PR list, the brief command must not
    # fall through to printing a green verdict. The stub's `pr` arm errors
    # out without a fixture, so `gh` writes nothing to stdout; the brief's
    # `jq -e 'type == "array"'` check then sees an empty string and the row
    # prints `verdict unknown` so the next checkup re-runs it. Same shape as
    # rows 8 and 9's fail-closed rule.
    out, _err, _status = run_command(
      command_cell('Dependabot is not stuck', gh_command: 'gh pr list'),
      jobs_fail: false
    ) { |_fixtures| } # no dependabot.prs fixture is written

    lines = out.lines.map(&:chomp)

    assert_equal 1, lines.size,
                 'an unreadable pr list prints exactly one line and nothing else; ' \
                 "got #{lines.inspect}"

    assert_includes lines.first, 'verdict unknown',
                    'an unreadable pr list must surface as `verdict unknown`, the same ' \
                    "fail-closed shape rows 8 and 9 use (stdout=#{out.inspect})"

    assert_includes lines.first, 'not readable',
                    'the line must also say the list was NOT READABLE: an unreadable ' \
                    'list and an empty one are different findings and must never look ' \
                    "alike (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on ',
                    'an unreadable pr list cannot have produced a stuck verdict ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, '0 open PRs',
                    'an unreadable list is not an empty one — that is the other ' \
                    "outcome (stdout=#{out.inspect})"
  end

  # Row 15's read is one contract with its report: the OPEN PRs, and the
  # fields the report prints. The stub refuses a `gh pr list` without
  # `--state open`, so a brief that fell back to `gh pr list`'s default state
  # fails closed instead of reporting whatever that state happened to be.
  def test_stub_refuses_a_pr_list_without_the_state_open_filter
    cell = command_cell('Dependabot is not stuck', gh_command: 'gh pr list')
    mutated = cell.sub('--state open ', '')

    refute_equal cell, mutated, 'the mutation must actually remove --state open'

    out, err, _status = run_row15(
      prs: [dependabot_pr(number: 7501, title: 'Bump rubocop from 2.0.0 to 2.1.0 in /',
                          branch: 'dependabot/bundler/rubocop', age_days: 35,
                          sha: SHA_RUBOCOP)],
      cell: mutated
    )

    assert_includes out, 'verdict unknown',
                    'a `gh pr list` without --state open is not the open-PR read the ' \
                    'row grades, and the stub refuses it ' \
                    "(stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'not readable',
                    "the refused read must say it is not readable (stdout=#{out.inspect})"

    refute_includes out, 'Dependabot is stuck on ',
                    "a refused read cannot have produced a stuck verdict (stdout=#{out.inspect})"
  end

  # The field list is the other half of the contract: the report prints the
  # branch, the head SHA and the last update, so a request that does not ask
  # for them is refused rather than answered with a report full of blanks.
  def test_stub_refuses_a_pr_list_that_does_not_request_the_head_sha
    cell = command_cell('Dependabot is not stuck', gh_command: 'gh pr list')
    mutated = cell.sub(',headRefOid', '')

    refute_equal cell, mutated, 'the mutation must actually drop headRefOid'

    out, err, _status = run_row15(
      prs: [dependabot_pr(number: 7502, title: 'Bump rubocop from 2.0.0 to 2.1.0 in /',
                          branch: 'dependabot/bundler/rubocop', age_days: 35,
                          sha: SHA_RUBOCOP)],
      cell: mutated
    )

    assert_includes out, 'verdict unknown',
                    'a request that does not ask for the head sha cannot fill the ' \
                    "report's per-PR line, and the stub refuses it (stdout=#{out.inspect}, " \
                    "stderr=#{err.inspect})"

    assert_includes out, 'not readable',
                    "the refused read must say it is not readable (stdout=#{out.inspect})"
  end

  # A readable but EMPTY list is a different finding from an unreadable one:
  # it is the answer "there is nothing open", not "I could not read".
  def test_readable_empty_pr_list_is_not_an_unknown
    out, _err, status = run_row15(prs: [])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_equal ['dependabot: 0 open PRs'], out.lines.map(&:chomp),
                 'a readable but empty pr list is its own outcome — "0 open PRs" — ' \
                 "not an unknown (stdout=#{out.inspect})"

    refute_includes out, 'verdict unknown',
                    'an empty list is a readable answer, not an unreadable one ' \
                    "(stdout=#{out.inspect})"
  end

  # The row reports what it read: one line per open PR, carrying the number,
  # the ecosystem, the branch, the head SHA and the last update.
  def test_row15_reports_each_open_pr_with_its_branch_head_sha_and_last_update
    pr = dependabot_pr(number: 7503, title: 'Bump rubocop from 2.0.0 to 2.1.0 in /',
                       branch: 'dependabot/bundler/rubocop', age_days: 5,
                       updated_days: 2, sha: SHA_RUBOCOP)
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    line = out.lines.map(&:chomp).find { |candidate| candidate.start_with?('#7503') }

    refute_nil line, "the row must report every open PR (stdout=#{out.inspect})"

    assert_equal ['#7503', 'bundler', 'dependabot/bundler/rubocop', SHA_RUBOCOP,
                  pr['updatedAt'], 'FAILURE'],
                 line.split,
                 'the per-PR line must carry the number, the ecosystem, the branch, ' \
                 "the head sha, the last update and the rolled-up state (got #{line.inspect})"
  end

  # A field the list does not carry is reported as `unknown` — never as an
  # empty slot and never as a literal `null`: the per-PR line has to stay
  # readable, and a blank would read as a PR with no head SHA at all.
  def test_row15_reports_unknown_for_a_field_the_list_does_not_carry
    # No headRefOid: the head SHA is read from that field and from nowhere
    # else, so a list that does not carry it can only report `unknown`.
    no_sha = dependabot_pr(number: 7514, title: 'Bump rubocop from 2.0.0 to 2.1.0 in /',
                           branch: 'dependabot/bundler/rubocop', age_days: 5)
    out, _err, status = run_row15(prs: [no_sha])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    line = out.lines.map(&:chomp).find { |candidate| candidate.start_with?('#7514') }

    refute_nil line, "the row must report every open PR (stdout=#{out.inspect})"

    assert_equal ['#7514', 'bundler', 'dependabot/bundler/rubocop', 'unknown',
                  no_sha['updatedAt'], 'FAILURE'],
                 line.split,
                 'a list that carries no head SHA must report `unknown` in the ' \
                 "head-sha slot (got #{line.inspect})"

    # No branch and no last update either: both slots read `unknown`, and
    # the ecosystem falls back to the title.
    bare = {
      'number' => 7515,
      'title' => 'Bump rubocop from 2.0.0 to 2.1.0 in /',
      'createdAt' => (Time.now.utc - (5 * 86_400)).iso8601,
      'statusCheckRollup' => [check_run('SUCCESS')]
    }
    out, _err, status = run_row15(prs: [bare])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    line = out.lines.map(&:chomp).find { |candidate| candidate.start_with?('#7515') }

    refute_nil line, "the row must report every open PR (stdout=#{out.inspect})"

    assert_equal ['#7515', 'bundler', 'unknown', 'unknown', 'unknown', 'SUCCESS'],
                 line.split,
                 'a list that carries no branch, no head SHA and no last update ' \
                 "must report `unknown` in each of those slots (got #{line.inspect})"
  end

  # The summary counts the open PRs per ecosystem and carries each
  # ecosystem's rolled-up state — the worst of its PRs' states.
  def test_row15_summary_counts_every_ecosystem_that_has_an_open_pr
    prs = [
      dependabot_pr(number: 7504, title: 'Bump rubocop from 2.0.0 to 2.1.0 in /',
                    branch: 'dependabot/bundler/rubocop', age_days: 5, sha: SHA_RUBOCOP),
      dependabot_pr(number: 7505, title: 'Bump @types/node from 20.0.0 to 20.1.0 in /frontend',
                    branch: 'dependabot/bun/@types/node', age_days: 5, sha: SHA_TYPES,
                    rollup: [check_run('SUCCESS')]),
      dependabot_pr(number: 7506, title: 'Bump actions/checkout from 4 to 5 in /',
                    branch: 'dependabot/github_actions/actions/checkout', age_days: 5,
                    sha: SHA_ACTIONS, rollup: [running_check_run])
    ]
    out, _err, status = run_row15(prs: prs)

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    summary = out.lines.map(&:chomp).first

    assert_match(/\Adependabot: 3 open PRs \(/, summary,
                 "the first line reports what was read (got #{summary.inspect})")

    ['bundler 1 FAILURE', 'bun 1 SUCCESS', 'github-actions 1 PENDING'].each do |entry|
      assert_includes summary, entry,
                      'the summary counts every ecosystem that has an open PR and ' \
                      "carries its rolled-up state (got #{summary.inspect})"
    end
  end

  # The summary carries each ecosystem's rolled-up state — the WORST of its
  # PRs' states, FAILURE outranking PENDING. Two bundler PRs, one red and one
  # green, roll up to `bundler 2 FAILURE`; one green and one still running
  # roll up to `bundler 2 PENDING`. A summary that carried the last PR's
  # state, or the best one, would report a red PR's ecosystem as green.
  def test_row15_summary_rolls_an_ecosystems_prs_up_to_their_worst_state
    green = dependabot_pr(number: 7511, title: 'Bump rake from 13.0.0 to 13.1.0 in /',
                          branch: 'dependabot/bundler/rake', age_days: 5,
                          sha: SHA_PR, rollup: [check_run('SUCCESS')])
    red = dependabot_pr(number: 7512, title: 'Bump rubocop from 2.0.0 to 2.1.0 in /',
                        branch: 'dependabot/bundler/rubocop', age_days: 5,
                        sha: SHA_RUBOCOP)

    out, _err, status = run_row15(prs: [green, red])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'dependabot: 2 open PRs (bundler 2 FAILURE)',
                    'one red PR among two makes the ecosystem FAILURE — the ' \
                    "worst state of its PRs' (stdout=#{out.inspect})"

    pending = dependabot_pr(number: 7513, title: 'Bump minitest from 5.0.0 to 5.1.0 in /',
                            branch: 'dependabot/bundler/minitest', age_days: 5,
                            sha: SHA_PR, rollup: [running_check_run])

    out, _err, status = run_row15(prs: [green, pending])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'dependabot: 2 open PRs (bundler 2 PENDING)',
                    'a green PR and a still-running one roll up to PENDING, not ' \
                    "to SUCCESS (stdout=#{out.inspect})"
  end

  # The branch carries the ecosystem (dependabot/<ecosystem>/...), so it is
  # read FIRST; the title is the fallback for a branch with no ecosystem
  # segment. Here the title would say bundler and the branch says docker:
  # the branch wins.
  def test_row15_reads_the_ecosystem_off_the_branch_first
    pr = dependabot_pr(number: 7507, title: 'Bump rubocop from 2.0.0 to 2.1.0 in /',
                       branch: 'dependabot/docker/oven/bun', age_days: 5, sha: SHA_DOCKER)
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, '#7507 docker dependabot/docker/oven/bun',
                    'the ecosystem must be read off the branch first ' \
                    "(stdout=#{out.inspect})"

    refute_includes out, '#7507 bundler',
                    'the title is the fallback, not the first read ' \
                    "(stdout=#{out.inspect})"
  end

  # A grouped bun PR's title and its branch disagree about the ecosystem.
  # Dependabot titles a grouped PR after the ecosystem ("Bump the bun group
  # with N updates"), and the title rules read ` group with .* updates$` as
  # github-actions — so a title-first read grades this PR against
  # github-actions' 37d budget and never reports it. The branch is read
  # FIRST: `dependabot/bun/...` is bun, whose 14d budget a 20d red PR is
  # past, so the row must name bun's budget and print the PR stuck.
  def test_row15_grades_a_grouped_bun_pr_off_its_branch_not_its_title
    pr = dependabot_pr(number: 7510, title: 'Bump the bun group with 3 updates',
                       branch: 'dependabot/bun/frontend-types-node', age_days: 20,
                       sha: SHA_TYPES)
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, '(age 20d > 14d budget for bun)',
                    'the branch carries the ecosystem, so a grouped bun PR is ' \
                    "graded against bun's 14d budget (stdout=#{out.inspect})"

    refute_includes out, 'budget for github-actions',
                    'the title says "group with N updates", which the title ' \
                    'rules read as github-actions; the branch is read first, so ' \
                    "the github-actions budget must not be applied (stdout=#{out.inspect})"

    assert_includes out, '#7510 bun dependabot/bun/frontend-types-node',
                    'the per-PR line reports the branch the ecosystem was read ' \
                    "from (stdout=#{out.inspect})"
  end

  def test_row15_falls_back_to_the_title_when_the_branch_carries_no_ecosystem
    pr = dependabot_pr(number: 7508, title: 'Bump actions/checkout from 4 to 5 in /',
                       branch: 'dependabot/renovate/actions/checkout', age_days: 5,
                       sha: SHA_ACTIONS)
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    assert_includes out, '#7508 github-actions dependabot/renovate/actions/checkout',
                    'a branch that carries no ecosystem segment falls back to the ' \
                    "title (stdout=#{out.inspect})"
  end

  # `updatedAt` is the PR's LAST UPDATE; the age a budget is graded against
  # is `createdAt`. A PR opened yesterday and touched a year ago is young, and
  # must never be graded on the update.
  def test_row15_reports_updated_at_but_grades_the_age_off_created_at
    pr = dependabot_pr(number: 7509, title: 'Bump rubocop from 2.0.0 to 2.1.0 in /',
                       branch: 'dependabot/bundler/rubocop', age_days: 1,
                       updated_days: 400, sha: SHA_RUBOCOP)
    out, _err, status = run_row15(prs: [pr])

    assert_predicate status, :success?,
                     "row 15's command must run cleanly (status=#{status.inspect})"

    refute_includes out, 'Dependabot is stuck on #7509',
                    'the age is graded off createdAt, never off updatedAt ' \
                    "(stdout=#{out.inspect})"

    assert_includes out, pr['updatedAt'],
                    'the last update is reported on the per-PR line ' \
                    "(stdout=#{out.inspect})"
  end

  # The budget map is unchanged — bundler 28d, bun 14d, github-actions 37d,
  # docker 37d — and a PR is stuck only when its age is STRICTLY past its
  # ecosystem's budget: exactly at the budget is not past it.
  def test_row15_budgets_are_unchanged_and_a_budget_is_strict
    {
      'bundler' => [28, 'Bump rubocop from 2.0.0 to 2.1.0 in /', 'dependabot/bundler/rubocop'],
      'bun' => [14, 'Bump @types/node from 20.0.0 to 20.1.0 in /frontend', 'dependabot/bun/@types/node'],
      'github-actions' => [37, 'Bump actions/checkout from 4 to 5 in /',
                           'dependabot/github_actions/actions/checkout'],
      'docker' => [37, 'Bump oven/bun from 1.4.1 to 1.4.2 in /', 'dependabot/docker/oven/bun']
    }.each do |eco, (budget, title, branch)|
      at_budget = dependabot_pr(number: 7600, title: title, branch: branch, age_days: budget, sha: SHA_PR)
      out, _err, _status = run_row15(prs: [at_budget])

      refute_includes out, 'Dependabot is stuck on ',
                      "a #{eco} PR aged exactly #{budget}d is AT its budget, not past " \
                      "it (stdout=#{out.inspect})"

      past_budget = dependabot_pr(number: 7601, title: title, branch: branch, age_days: budget + 1, sha: SHA_PR)
      # A past-budget docker PR is graded through the pin discriminator read, so
      # that read has to be readable here: an unrelated failing test keeps the
      # stuck verdict (and the budget line) intact.
      runs = { SHA_PR => failed_run_log(
        'Failure: test_something_else [test/unit/some_other_test.rb:12]:'
      ) }
      out, _err, _status = run_row15(prs: [past_budget], runs: runs)

      assert_match(/\(age #{budget + 1}d > #{budget}d budget for #{Regexp.escape(eco)}\)/, out,
                   "a #{eco} PR aged #{budget + 1}d is past its #{budget}d budget, and " \
                   "the line must name that budget (stdout=#{out.inspect})")
    end
  end

  def test_brief_cites_one_contiguous_range_for_the_proceed_signal
    # The no-op step used to split its evidence across two anchors
    # (release.yml:80-86 for the emit, release.yml:88-90 for the gate), leaving
    # the one thing a maintainer goes to read — where proceed=false comes from
    # — to be assembled from two places. One range fixes that, and the range
    # must still hold both halves: an anchor naming lines that no longer decide
    # proceed points a reader at nothing.
    step = no_op_step

    assert_includes step, 'release.yml:80-90',
                    'the no-op step must cite ONE contiguous range for the proceed ' \
                    "signal; got the step as #{step.inspect}"

    %w[release.yml:80-86 release.yml:88-90].each do |split|
      refute_includes step, split,
                      "the proceed signal is still cited as #{split} and something else; " \
                      'the row must name one range a reader can open'
    end

    workflow = File.readlines(RELEASE_WORKFLOW)

    assert_operator workflow.size, :>=, 90,
                    'release.yml no longer has the lines the brief anchor cites'

    cited = workflow[79..89].join

    assert_includes cited, 'proceed=false',
                    'release.yml:80-90 must be where preflight writes proceed=false'
    assert_includes cited, "needs.preflight.outputs.proceed == 'true'",
                    'release.yml:80-90 must be where the release job reads the proceed signal'
  end

  def test_brief_cites_one_contiguous_range_for_the_non_main_refusal
    # The non-main refusal is one of two failure modes the no-op paragraph
    # distinguishes from a proceed=false no-op: preflight failing the
    # `refs/heads/main` guard produces the same all-skipped signature as a
    # no-op, and the brief grounds that on the exact step that refuses. The
    # cite must still land on a FAILING step (exit 1), not on a job-level
    # `if:` — a skipped preflight would skip release too and leave a green
    # run that published nothing and said nothing. Insert lines above the
    # cite and the slice no longer matches.
    para = non_main_refusal_step

    assert_includes para, 'release.yml:55-60',
                    'the non-main refusal paragraph must cite the step by ' \
                    "one contiguous range; got the paragraph as #{para.inspect}"

    workflow = File.readlines(RELEASE_WORKFLOW)

    assert_operator workflow.size, :>=, 60,
                    'release.yml no longer has the lines the brief anchor cites'

    cited = workflow[54..59].join

    assert_equal '- name: refuse any ref but main', workflow[54].strip,
                 'release.yml:55-60 must LAND on the step line itself — a comment or ' \
                 'blank line inserted above the cite shifts the slice but the step name ' \
                 'would still match inside it, so the top edge must be pinned to the step, ' \
                 'not a comment one above it'
    assert_includes cited, '- name: refuse any ref but main',
                    'release.yml:55-60 must name the step that refuses a non-main ref'
    assert_includes cited, 'refs/heads/main',
                    'release.yml:55-60 must hold the ref guard — otherwise a non-main ref could pass'
    assert_includes cited, 'exit 1',
                    'release.yml:55-60 must terminate in a failing exit, not a job-level `if:` — ' \
                    'a skipped preflight would skip release too and leave a green run that ' \
                    'published nothing and said nothing'
  end

  def test_no_op_step_cites_one_contiguous_range_for_the_demo_needs
    # The no-op step also grounds the `demo skipped` arm of the signature on
    # `demo` needing `[preflight, release]`. The cited range must still hold
    # the demo caller and its needs list — a maintainer reads that line to
    # understand why the demo slot is quiet on a proceed=false run, and the
    # only reason it is quiet is `release` being gated on the proceed signal.
    # Insert lines above this anchor and the demo caller is pushed out of
    # the slice.
    step = no_op_step

    assert_includes step, 'release.yml:222-228',
                    'the no-op step must cite the demo call by one contiguous ' \
                    "range; got the step as #{step.inspect}"

    workflow = File.readlines(RELEASE_WORKFLOW)

    assert_operator workflow.size, :>=, 228,
                    'release.yml no longer has the lines the brief anchor cites'

    cited = workflow[221..227].join

    assert_equal 'demo:', workflow[221].strip,
                 'release.yml:222-228 must LAND on the demo caller itself — a comment or ' \
                 'blank line inserted above the cite shifts the slice but `demo:` and its ' \
                 '`needs:` line still match inside it, so the top edge must be pinned to ' \
                 'the job header, not a comment one above it'
    assert_includes cited, 'demo:',
                    'release.yml:222-228 must begin on the demo caller job'
    assert_includes cited, 'needs: [preflight, release]',
                    "release.yml:222-228 must hold the demo caller's needs list — " \
                    'that is what makes its slot quiet when preflight returns proceed=false'
  end

  def test_each_job_list_row_requests_url_and_database_id
    # The ask rule (bottom of the brief) says the body's carry the command, its
    # output AND the run URL. The rows can only print that URL if they ask for
    # it, and a `--json` list that loses `url` (or the `databaseId` the jobs
    # call is built from) silently degrades to a bare `jq -r .url` printing the
    # string `null` — a filed link that goes nowhere. Pin the field list per row.
    ['`main` is green',
     'the last release published',
     'the demo deployed',
     'topology and ecosystem lanes'].each do |signal|
      command = command_cell(signal)
      json_list = command[/--json ([a-zA-Z,]+)/, 1]

      refute_nil json_list,
                 "the #{signal.inspect} row must pass an explicit `--json` field " \
                 'list to `gh run list`; without one there is no field to pin'

      %w[url databaseId].each do |field|
        assert_includes json_list.split(','), field,
                        "the #{signal.inspect} row must request `#{field}` from " \
                        "`gh run list --json #{json_list}`: the ask needs the run URL " \
                        'and the jobs call is built from the databaseId'
      end
    end
  end

  def test_job_list_rows_print_the_run_url_with_every_verdict
    # The URL has to survive into every branch, not just the green one: a
    # duplicate-skipped push, an ungraded line and a no-op are exactly the
    # lines a reader has to follow back to the run.
    out, = run_row8(jobs: jobs_json(detect: 'success', gate: 'skipped'),
                    conclusion: 'success', sha: SHA_DUP)

    assert_includes out, URL_TEST,
                    "a duplicate-skipped verdict must carry the run url too; got #{out.inspect}"

    out, = run_row8(jobs: jobs_json(detect: 'success', gate: 'skipped'),
                    conclusion: 'success', sha: SHA_DUP, jobs_fail: true)

    assert_includes out, URL_TEST,
                    'an ungraded (`evidence unavailable`) line must still carry the run ' \
                    "url; got #{out.inspect}"

    out, = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'skipped', demo: 'skipped'),
                    conclusion: 'success', sha: SHA_NOOP)

    assert_includes out, URL_RELEASE,
                    "a no-op line must carry the run url; got #{out.inspect}"

    out, = run_row14

    assert_includes out, URL_TOPOLOGY,
                    "the reused lane's duplicate-skipped line must carry its run url; got #{out.inspect}"
    assert_includes out, URL_ECOSYSTEM,
                    "the healthy lane's line must carry its own run url; got #{out.inspect}"

    out, = run_row12(jobs: demo_jobs_json, log: resolve_log(short: DEMO_TAG),
                     conclusion: 'success', sha: SHA_DEMO)

    assert_includes out, URL_DEMO,
                    "row 12's graded verdict must carry the run url too, like every " \
                    "other job-list row's; got #{out.inspect}"
  end

  def test_brief_documents_how_to_confirm_the_dup_signature
    # The rows grade the dup from a runtime signature, so a reader has to be
    # able to check it against the run. The confirm-against-the-run paragraph
    # must name the job and step that prints it, the grep, and both outcomes —
    # `— skipping` (dup) versus `— full run` with a reason (not a dup). Every
    # assertion reads THAT paragraph, so a phrase sitting elsewhere in the brief
    # cannot stand in for documentation that was never written.
    para = dup_confirmation

    assert_includes para, 'duplicate of an already-green PR head (dup)',
                    'the confirm-the-dup paragraph must name the log step that runs ' \
                    'bin/ci-dup-push, so a reader knows which log to open'

    assert_includes para, 'bin/ci-dup-push',
                    'the paragraph must name the script whose stderr carries the verdict'

    assert_includes para, 'gh run view',
                    'the paragraph must give the command that reads the run log'
    assert_includes para, 'ci-dup-push:',
                    'the paragraph must give the grep the reader runs over that log'

    assert_includes para, '— skipping',
                    'dup=true must be readable as `— skipping`'
    assert_includes para, '— full run',
                    'dup=false must be readable as `— full run`, and the paragraph ' \
                    'must say it carries the reason the run did not skip'
    assert_match(/— full run[^.]*reason|reason[^.]*— full run/, para,
                 'dup=false must be distinguishable from dup=true by more than the ' \
                 "em dash alone; got #{para.inspect}")

    assert_includes para, 'detect changed paths',
                    'the paragraph must anchor the log read to the `detect changed paths` job'

    assert_match(/grading it does not change|does not change it|still does not grade as a dup/,
                 para,
                 'the paragraph confirms the signature and must say so without ' \
                 "weakening the grading; got #{para.inspect}")
  end

  def test_dup_grading_stays_fail_closed_after_the_documentation
    # The confirm-the-dup paragraph must not have relaxed the grading it
    # documents: a failed detect is still not a dup, and an unreadable job
    # list is still `evidence unavailable`.
    out, = run_row8(jobs: jobs_json_after_failed_detect,
                    conclusion: 'failure', sha: SHA_DUP)

    refute_includes out, 'Unhealthy',
                    'documenting the dup signature must not turn a failed detect into ' \
                    "a dup; got #{out.inspect}"

    refute_includes out, 'duplicate-skipped',
                    "a failed detect is not a reused tree; got #{out.inspect}"

    out, = run_row8(jobs: jobs_json(detect: 'success', gate: 'skipped'),
                    conclusion: 'success', sha: SHA_DUP, jobs_fail: true)

    assert_includes out, 'evidence unavailable',
                    "the fail-closed unknown grade must survive; got #{out.inspect}"
  end

  # The filing rule has to say what is NOT filed. A `no run: <workflow> has
  # no matching run` line means the workflow has no run to grade: there is
  # no run to link, so an ask built from it would name nothing a maintainer
  # could act on. It must never be filed under one of the rows' Unhealthy
  # titles — those titles are the signal's stable name, and filing an empty
  # run list under `main is red` would suppress the ask a real red main
  # files.
  def test_filing_rule_excludes_the_empty_run_list_outcome
    para = filing_paragraph

    assert_includes para, 'no run:',
                    'the filing paragraph must name the empty-run-list outcome, or a ' \
                    'reader filing asks will not know it is not one of them; got ' \
                    "#{para.inspect}"

    assert_match(/no run:[^.]*files no ask/i, para,
                 'the filing paragraph must say the empty run-list outcome files NO ' \
                 "ask; got #{para.inspect}")

    assert_match(/never (be )?filed under/i, para,
                 'the filing paragraph must say the empty outcome is never filed under ' \
                 "a row's Unhealthy titles; got #{para.inspect}")
  end

  # The filing rule's last sentence is the ask-body contract: six named
  # evidence elements the body carries. This pins the BRIEF TEXT only — the
  # platform that generates ask bodies lives outside this checkout, so each
  # assertion requires the brief's filing paragraph to name the element, and
  # says nothing about what a generated body contains. The sentence is
  # extracted first (it cannot span a full stop), so a `headSha` mention in
  # the trigger sentence cannot stand in for a deleted body element.
  def test_filed_ask_body_carries_the_six_evidence_elements
    sentence = filing_paragraph[/[^.]*body carries[^.]*/]
    raise "health.md's filing paragraph has no sentence saying what the body carries" if sentence.nil?

    {
      'the command' => 'the command that produced the verdict',
      'its output' => 'the output that command printed',
      'the run URL' => 'the run URL the ask links',
      'the headSha' => 'the headSha the run graded',
      'the version' => 'the version the run carried',
      'the PR age' => 'the PR age the verdict weighed'
    }.each do |element, description|
      assert_includes sentence, element,
                      "the filing rule's body sentence must name #{element} (#{description}) as " \
                      'part of the evidence a filed ask\'s body carries; the brief no longer ' \
                      "requires it; got #{sentence.inspect}"
    end
  end

  def test_filing_paragraph_carries_the_release_due_issues_lookup
    para = filing_paragraph

    assert_includes para, lookup_command,
                    'the filing paragraph must name the issues lookup verbatim, in one ' \
                    "backtick span; got #{para.inspect}"

    release_text = File.read(RELEASE_DUE_BRIEF)

    assert_includes release_text, "`#{lookup_command}`",
                    'health.md must dedupe against the byte-identical issues lookup ' \
                    'release-due.md runs: two briefs deduping against different lists means ' \
                    "one lane's guard never sees what the other filed"
  end

  def test_issues_lookup_drops_pull_requests_from_the_open_list
    # GitHub's /issues route returns pull requests alongside issues, so the
    # `.pull_request == null` filter is load-bearing: without it a PR title
    # would read as a filed ask and suppress one nobody has filed. Pinned by
    # RUNNING the extracted command against a stubbed gh, not by substring.
    issues = JSON.generate(
      [{ 'number' => 7, 'title' => 'main is red' },
       { 'number' => 8, 'title' => 'swarm: stop leaking parent sockets on fork',
         'pull_request' => { 'url' => 'https://api.github.com/repos/developerz-ai/wurk/pulls/8' } }]
    )

    out, err, status = run_command(lookup_command, jobs_fail: false) do |fixtures|
      write_fixture(fixtures, 'issues.json', issues)
    end

    assert_predicate status, :success?,
                     'the dedupe lookup must run cleanly against the stubbed gh ' \
                     "(status=#{status.inspect}, stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'main is red',
                    'an open issue titled exactly like the signal must come back from the ' \
                    'lookup, or a real ask could never be deduped against it; ' \
                    "got stdout=#{out.inspect}, stderr=#{err.inspect}"

    refute_includes out, 'swarm: stop leaking parent sockets on fork',
                    'the entry carrying a pull_request key is a PR, not an issue: the filter ' \
                    'must drop it or its title would stand in for an ask that was never filed; ' \
                    "got stdout=#{out.inspect}"
  end

  def test_ask_titles_are_stable_per_signal
    para = filing_paragraph

    ['`main is red`', '`release did not publish`', '`demo deploy failed`'].each do |title|
      assert_includes para, title,
                      'the dedupe match is exact equality on the title, so every title the ' \
                      'brief gives must be the signal\'s stable name, identical on every ' \
                      "occurrence; the filing paragraph is missing #{title}"
    end

    ['`main is red at <sha>`',
     '`release <v> did not publish`'].each do |old_title|
      refute_includes para, old_title,
                      "#{old_title} embeds what changes run to run, so an exact-match dedupe " \
                      'against it can never hit and the ask is re-filed on every checkup'
    end

    %w[<sha> <v>].each do |token|
      refute_includes para, token,
                      "#{token} is run-specific and may name no part of a title: refer to it " \
                      'in prose (headSha, version) and carry the value in the body'
    end
  end

  def test_a_red_run_still_files_its_stable_ask_title
    para = filing_paragraph

    ['`main is red`', '`topology.yml is red`', '`ecosystem.yml is red`'].each do |title|
      assert_includes para, title,
                      'a red run still files one deduped ask, and its title is the ' \
                      'signal\'s stable name, identical on every occurrence; the filing ' \
                      "paragraph is missing #{title}"
    end
  end

  # A failed run is graded on its own conclusion — rows 8, 9, 12 and 14 print that
  # conclusion beside the headSha and the run URL, with no `Unhealthy:` prefix
  # on it — so a filing rule keyed to `Unhealthy:` lines alone never files the
  # red-main, red-release or red-lane ask its own stable titles name. The rule
  # must retain the failed-run conclusion line as a filing trigger beside the
  # `Unhealthy:` verdicts, while every non-defect outcome stays unfiled.
  def test_filing_rule_retains_a_failed_runs_conclusion_line
    para = filing_paragraph.gsub(/\s+/, ' ')

    assert_includes para, "a failed run's own conclusion line",
                    'the filing paragraph must name the failed-run conclusion line as a filing ' \
                    'trigger: rows 8, 9, 12 and 14 grade a genuinely red run on its own conclusion, ' \
                    'which prints no `Unhealthy:` prefix, so a rule keyed to `Unhealthy:` ' \
                    'verdicts alone would file no ask for a red main, release or lane; ' \
                    "got #{para.inspect}"

    assert_includes para,
                    'that line is the trigger `main is red`, `release did not publish`, ' \
                    '`demo deploy failed`, `topology.yml is red` and `ecosystem.yml is red` are filed from',
                    'the failed-run conclusion line must be tied to the red-run ask titles it is ' \
                    "the trigger for; got #{para.inspect}"

    assert_match(/Everything else a row can print[^.]*`no-op`[^.]*files nothing/, para,
                 'the rule must keep every non-defect outcome unfiled beside the new trigger: ' \
                 'a readable success, a reused tree, unreadable evidence and an in-flight or ' \
                 "no-op run name no defect; got #{para.inspect}")

    assert_match(/`verdict unknown \.\.\. not readable`[^.]*files no ask/i, para,
                 'a row that could not read its list establishes nothing, so its ' \
                 '`verdict unknown ... not readable` line files no ask either; ' \
                 "got #{para.inspect}")
  end

  def test_a_reused_tree_files_no_ask
    para = filing_paragraph

    ['`main is green only via a dup\'d push`',
     '`topology.yml is green only via a dup\'d push`',
     '`ecosystem.yml is green only via a dup\'d push`'].each do |title|
      refute_includes para, title,
                      'a duplicate-skipped push reused a tree that already passed that ' \
                      'workflow, so it is neither a green nor a red signal: it files no ' \
                      "ask, and the filing rule must not offer one (#{title})"
    end
  end

  # The classification is only as good as the evidence the brief says it
  # reads: the job list, the `detect changed paths` job's conclusion, every
  # gated job's conclusion and every gated job's step conclusions. A reader who
  # cannot see those cannot tell a reused tree from a run that ran nothing, and
  # the brief must say that an unreadable list is not verified main health.
  def test_the_dup_prose_names_the_evidence_the_classification_reads
    para = dup_grading_block

    assert_includes para, 'gh api repos/$repo/actions/runs/<databaseId>/jobs',
                    'the dup prose must name the jobs list the classification reads'

    assert_includes para, 'detect changed paths',
                    "the classification reads the `detect changed paths` job's conclusion; " \
                    "got #{para.inspect}"

    assert_match(/every gated job/, para,
                 "the classification reads every gated job's conclusion; got #{para.inspect}")

    assert_includes para, 'not verified main health',
                    'an unreadable job list is not verified main health, and the prose ' \
                    "must say so; got #{para.inspect}"

    CLASSIFICATIONS.each do |token|
      assert_includes para, token,
                      "the prose must name the #{token} verdict, or a reader cannot " \
                      "tell the classes apart; got #{para.inspect}"
    end
  end

  # The dedupe match is EXACT EQUALITY on a title, so a title carrying a value
  # that changes run to run can never match an open ask: the same ask is
  # re-filed on every checkup. Row 10's title names the CONSTANT; its VALUE is
  # what changes, so the constant's name is what the title carries.
  def test_the_rubygems_ask_title_names_the_constant_and_never_its_value
    assert_filing_ask_title(@text, '`RubyGems does not serve Wurk::VERSION`',
                            resolved: /`RubyGems does not serve [^`]*\d/)
  end

  # A gem-less Latest Release is a release-lane defect with its own ask, and
  # its title carries nothing that changes run to run — one stable name is all
  # the exact-match dedupe needs.
  def test_the_gem_less_release_ask_title_is_stable
    assert_filing_ask_title(@text, '`GitHub Release is gem-less`')
  end

  # The missing-tag verdict is a DIFFERENT defect from a failed deploy and
  # files its own ask, so the two never collapse into one title. The image tag
  # is the run-specific part, so it stays a placeholder in the title.
  def test_the_frozen_demo_ask_title_keeps_the_sha_placeholder
    assert_filing_ask_title(@text, '`demo frozen: no sha-<7> image tag`',
                            resolved: /`demo frozen: no sha-[0-9a-f]/)
  end

  # The served-version row is a second demo defect with its own ask. The
  # version it compares changes run to run, so the title names the comparison
  # and never the version.
  def test_the_served_version_demo_ask_title_is_stable
    assert_filing_ask_title(@text, '`demo serves a different version than the checkout`',
                            resolved: /`demo serves a different version [^`]*\d/)
  end

  # One ask per stuck PR: the PR number is stable for that PR's lifetime and
  # keeps two stuck PRs distinguishable, so it belongs IN the title — as the
  # placeholder, never as the resolved number.
  def test_the_stuck_dependabot_ask_title_keeps_the_pr_number_placeholder
    assert_filing_ask_title(@text, '`Dependabot is stuck on #<n>`',
                            resolved: /`Dependabot is stuck on #\d/)
  end

  # A waiting-on-us docker bump is a DIFFERENT defect from a stuck PR: the
  # owner can act on it, so it files its own ask and never the stuck one. Its
  # PR number is the same stable part, and it stays a placeholder.
  def test_the_waiting_docker_bump_ask_title_keeps_the_pr_number_placeholder
    assert_filing_ask_title(@text, '`Docker bump #<n> is waiting on us`',
                            resolved: /`Docker bump #\d/)
  end

  # A guard that cannot fail is not a guard: the six assertions above pass on a
  # brief that never carried the title at all, so every form needs a mutation
  # that renames or removes its title in a COPY of the brief and shows the
  # guard rejecting it. The mutation is proved first, so a copy that never
  # changed cannot pass the test vacuously.
  def test_the_rubygems_ask_title_guard_rejects_a_renamed_title
    title = '`RubyGems does not serve Wurk::VERSION`'
    text = @text.sub(title, '`RubyGems does not serve the checkout version`')

    refute_equal @text, text,
                 'the mutation must have landed before the guard is exercised'

    refute_includes text, title,
                    'the renamed title must be gone before the guard is exercised'

    error = assert_raises(Minitest::Assertion) do
      assert_filing_ask_title(text, title, resolved: /`RubyGems does not serve [^`]*\d/)
    end

    assert_includes error.message, 'the filing paragraph is missing',
                    'the guard must fail BECAUSE the filing paragraph lost the title'
  end

  def test_the_gem_less_release_ask_title_guard_rejects_a_removed_title
    title = '`GitHub Release is gem-less`'
    text = @text.sub(title, '')

    refute_equal @text, text,
                 'the mutation must have landed before the guard is exercised'

    refute_includes text, title,
                    'the removed title must be gone before the guard is exercised'

    error = assert_raises(Minitest::Assertion) do
      assert_filing_ask_title(text, title)
    end

    assert_includes error.message, 'the filing paragraph is missing',
                    'the guard must fail BECAUSE the filing paragraph lost the title'
  end

  def test_the_frozen_demo_ask_title_guard_rejects_a_renamed_title
    title = '`demo frozen: no sha-<7> image tag`'
    text = @text.sub(title, '`demo frozen: no image tag`')

    refute_equal @text, text,
                 'the mutation must have landed before the guard is exercised'

    refute_includes text, title,
                    'the renamed title must be gone before the guard is exercised'

    error = assert_raises(Minitest::Assertion) do
      assert_filing_ask_title(text, title, resolved: /`demo frozen: no sha-[0-9a-f]/)
    end

    assert_includes error.message, 'the filing paragraph is missing',
                    'the guard must fail BECAUSE the filing paragraph lost the title'
  end

  def test_the_served_version_demo_ask_title_guard_rejects_a_removed_title
    title = '`demo serves a different version than the checkout`'
    text = @text.sub(title, '')

    refute_equal @text, text,
                 'the mutation must have landed before the guard is exercised'

    refute_includes text, title,
                    'the removed title must be gone before the guard is exercised'

    error = assert_raises(Minitest::Assertion) do
      assert_filing_ask_title(text, title, resolved: /`demo serves a different version [^`]*\d/)
    end

    assert_includes error.message, 'the filing paragraph is missing',
                    'the guard must fail BECAUSE the filing paragraph lost the title'
  end

  def test_the_stuck_dependabot_ask_title_guard_rejects_a_renamed_title
    title = '`Dependabot is stuck on #<n>`'
    text = @text.sub(title, '`Dependabot is stuck on a pull request`')

    refute_equal @text, text,
                 'the mutation must have landed before the guard is exercised'

    refute_includes text, title,
                    'the renamed title must be gone before the guard is exercised'

    error = assert_raises(Minitest::Assertion) do
      assert_filing_ask_title(text, title, resolved: /`Dependabot is stuck on #\d/)
    end

    assert_includes error.message, 'the filing paragraph is missing',
                    'the guard must fail BECAUSE the filing paragraph lost the title'
  end

  def test_the_waiting_docker_bump_ask_title_guard_rejects_a_removed_title
    title = '`Docker bump #<n> is waiting on us`'
    text = @text.sub(title, '')

    refute_equal @text, text,
                 'the mutation must have landed before the guard is exercised'

    refute_includes text, title,
                    'the removed title must be gone before the guard is exercised'

    error = assert_raises(Minitest::Assertion) do
      assert_filing_ask_title(text, title, resolved: /`Docker bump #\d/)
    end

    assert_includes error.message, 'the filing paragraph is missing',
                    'the guard must fail BECAUSE the filing paragraph lost the title'
  end

  # The resolved-value refusal is a guard of its own, and the six mutation
  # tests above cannot prove it: each of them renames or removes the title,
  # so the guard fails on the MISSING title and never reaches the refusal. A
  # brief whose title carried a resolved sha, version or PR number would pass
  # every one of them. Each copy below keeps the placeholder title AND adds
  # the resolved variant, so the resolved value is the only thing left for the
  # guard to refuse.
  def test_the_rubygems_ask_title_guard_rejects_a_resolved_value
    assert_resolved_ask_title_rejected('`RubyGems does not serve Wurk::VERSION`',
                                       resolved: /`RubyGems does not serve [^`]*\d/,
                                       resolved_title: '`RubyGems does not serve 1.2.3`')
  end

  def test_the_frozen_demo_ask_title_guard_rejects_a_resolved_value
    assert_resolved_ask_title_rejected('`demo frozen: no sha-<7> image tag`',
                                       resolved: /`demo frozen: no sha-[0-9a-f]/,
                                       resolved_title: '`demo frozen: no sha-7a7a7a7 image tag`')
  end

  def test_the_served_version_demo_ask_title_guard_rejects_a_resolved_value
    assert_resolved_ask_title_rejected('`demo serves a different version than the checkout`',
                                       resolved: /`demo serves a different version [^`]*\d/,
                                       resolved_title: '`demo serves a different version 9.9.9`')
  end

  def test_the_stuck_dependabot_ask_title_guard_rejects_a_resolved_value
    assert_resolved_ask_title_rejected('`Dependabot is stuck on #<n>`',
                                       resolved: /`Dependabot is stuck on #\d/,
                                       resolved_title: '`Dependabot is stuck on #123`')
  end

  def test_the_waiting_docker_bump_ask_title_guard_rejects_a_resolved_value
    assert_resolved_ask_title_rejected('`Docker bump #<n> is waiting on us`',
                                       resolved: /`Docker bump #\d/,
                                       resolved_title: '`Docker bump #456 is waiting on us`')
  end

  private

  # The jobs declared in .github/workflows/test.yml, keyed by job id. Read with
  # `safe_load_file(..., aliases: true)`: Psych 4/5 make `load_file` a safe
  # load with aliases DISABLED, so a workflow that grows a YAML anchor would
  # raise Psych::AliasesNotEnabled instead of failing the guard cleanly.
  # test.yml carries no date or time scalars, so no class has to be permitted.
  def workflow_jobs
    workflow = YAML.safe_load_file(File.join(ROOT, '.github', 'workflows', 'test.yml'), aliases: true)
    jobs = workflow.is_a?(Hash) ? workflow['jobs'] : nil
    raise '.github/workflows/test.yml declares no jobs' unless jobs.is_a?(Hash)

    jobs
  end

  # The display names a parsed workflow's jobs carry.
  def workflow_job_names(jobs)
    jobs.values.filter_map { |spec| spec.is_a?(Hash) ? spec['name'] : nil }
  end

  # The selectors no job in the parsed workflow carries. Empty when every
  # selector names a job — the guard passes.
  def job_name_selector_violations(jobs)
    names = workflow_job_names(jobs)

    JOB_NAME_SELECTORS.reject { |selector| names.include?(selector) }
  end

  # The guard itself: every selector the brief's rows (and this file's own
  # fixtures) use must be the display name of a job in test.yml. Membership,
  # not equality — unrelated jobs may come and go.
  def assert_job_name_selectors_present(jobs)
    names = workflow_job_names(jobs)

    JOB_NAME_SELECTORS.each do |selector|
      assert_includes names, selector,
                      "health.md and this file's fixtures select jobs by the display name " \
                      "`#{selector}`, but no job in .github/workflows/test.yml carries that " \
                      '`name:` — rename the selector with the job (names present: ' \
                      "#{names.inspect})"
    end
  end

  # The "Grading a demo deploy" prose block — row 12's graded convention, from
  # its heading up to the filing convention that follows it. Bounded on that
  # paragraph, not on the next `**`, so the "Green is necessary, not
  # sufficient" sub-heading stays inside the block it belongs to.
  def demo_block
    lines = @text.lines.map(&:chomp)
    first = lines.index { |line| line.start_with?('**Grading a demo deploy') }

    raise 'health.md has no "Grading a demo deploy" block' if first.nil?

    last = ((first + 1)...lines.size).find { |i| lines[i].start_with?('For each unhealthy signal') }
    raise 'the demo block is not followed by the filing convention' if last.nil?

    lines[first...last].join("\n")
  end

  # The brief's "Grading dependabot" block — the prose that says how each open
  # PR is graded, what the rollup means, and what the docker pin carve-out
  # depends on. Bounded on the next '**'-starting line, so the filing
  # convention that follows stays out of it.
  def dependabot_grading_block
    lines = @text.lines.map(&:chomp)
    first = lines.index { |line| line.start_with?('**Grading dependabot') }

    raise 'health.md has no "Grading dependabot" block' if first.nil?

    last = ((first + 1)...lines.size).find { |i| lines[i].start_with?('**') } || lines.size

    lines[first...last].join("\n")
  end

  # The brief's "Grading a dup'd push" block — the prose that says how a push
  # run is classified and which evidence the classification is read from.
  # Bounded on the next '**'-starting line, so the release paragraph that
  # follows stays out of it.
  def dup_grading_block
    lines = @text.lines.map(&:chomp)
    first = lines.index { |line| line.start_with?('**Grading a dup') }

    raise 'health.md has no "Grading a dup\'d push" block' if first.nil?

    last = ((first + 1)...lines.size).find { |i| lines[i].start_with?('**') } || lines.size

    lines[first...last].join("\n")
  end

  # The classes a verdict names. A line carrying two of them (or none) is a
  # classification the reader cannot act on.
  def classifications(out)
    CLASSIFICATIONS.select { |token| out.include?(token) }
  end

  # The brief's paragraph telling a reader how to confirm a dup'd push against
  # the run itself — the one anchored to the `duplicate of an already-green PR
  # head (dup)` log step. Scoping the assertions to it keeps a phrase elsewhere
  # in the brief from satisfying them.
  def dup_confirmation
    lines = @text.lines.map(&:chomp)
    first = lines.index { |line| line.include?('Confirming the signature') }

    raise 'health.md has no paragraph documenting how to confirm the dup signature' if first.nil?

    last = ((first + 1)...lines.size).find { |i| lines[i].start_with?('**') } || lines.size

    lines[first...last].join("\n")
  end

  # The brief's step-3 bullet — the one reading `preflight` success + `release`
  # skipped as a no-op — as one string, so an assertion about the anchor cannot
  # be satisfied by that anchor appearing somewhere else in the file.
  def no_op_step
    lines = @text.lines.map(&:chomp)
    first = lines.index { |line| line.start_with?('3. **') && line.include?('no-op') }

    raise 'health.md has no step 3 reading preflight+release-skipped as a no-op' if first.nil?

    last = ((first + 1)...lines.size).find { |i| lines[i].start_with?('4. **') }
    raise 'health.md step 3 is not followed by a step 4' if last.nil?

    lines[first...last].join("\n")
  end

  # The brief's step-6 bullet — the waiting-on-us classification with its
  # head-pins verification — as one string, so an assertion about the
  # verification cannot be satisfied by prose somewhere else in the file.
  def waiting_step
    lines = @text.lines.map(&:chomp)
    first = lines.index { |line| line.start_with?('6. **') && line.include?('waiting') }

    raise 'health.md has no step 6 for the waiting-on-us classification' if first.nil?

    last = ((first + 1)...lines.size).find { |i| lines[i].start_with?('A PR past budget') } || lines.size

    lines[first...last].join("\n")
  end

  # The brief's step-5 bullet — the docker pin carve-out — as one string, so
  # an assertion about its prose cannot be satisfied by a mention somewhere
  # else in the file. The dup block also carries a step 5 (its `executed`
  # verdict), so the line has to carry the carve-out's own word too.
  def docker_pin_carve_out_step
    lines = @text.lines.map(&:chomp)
    first = lines.index { |line| line.start_with?('5. **') && line.include?('carve-out') }

    raise 'health.md has no step-5 docker pin carve-out bullet' if first.nil?

    last = ((first + 1)...lines.size).find { |i| lines[i].start_with?('6. **') }
    raise 'health.md step 5 is not followed by a step 6' if last.nil?

    lines[first...last].join("\n")
  end

  # The brief's "a run that genuinely went red stays Unhealthy" paragraph —
  # the one naming the non-main refusal failure mode (release.yml:55-60) that
  # produces the same all-skipped signature as a proceed=false no-op. Scoping
  # the assertion here keeps a `release.yml:55-60` citation elsewhere in the
  # file from satisfying it.
  def non_main_refusal_step
    lines = @text.lines.map(&:chomp)
    first = lines.index { |line| line.include?('non-main refusal') }

    raise 'health.md has no paragraph documenting the non-main refusal' if first.nil?

    last = ((first + 1)...lines.size).find { |i| lines[i].start_with?('**') } || lines.size

    lines[first...last].join("\n")
  end

  # A `gh api repos/.../actions/runs/<id>/jobs` response shaped like the real
  # one: `detect changed paths` plus the gated jobs. These workflows gate every
  # job PER STEP (`RUN: needs.detect.outputs.dup != 'true'` with
  # `if: env.RUN == 'true'` on each step — test.yml:153-157), so a job whose
  # gate did not run still reports `success` and every one of its steps reports
  # `skipped` — except the runner's own `Set up job` and `Complete job`, the
  # steps bracketing every job, which conclude `success` even here. That is
  # the shape a dup'd push produces; the job-level `skipped` this fixture
  # used to fabricate never occurs, and a `gate_steps` filter excepting only
  # `Set up job` graded a dup'd run that carries `Complete job` as `executed`.
  # `gate:` is what the gated jobs' own step concluded — `skipped` when the
  # gate did not run, `success` when it did — and the job's own conclusion
  # follows it, except for a skipped gate: a job whose steps were all skipped
  # still concludes `success`.
  # `sidekiq release watcher` is ecosystem.yml's schedule/dispatch-only job —
  # it is skipped on every push (a job-level `if:`), which is why row 14
  # excludes it by name. It belongs to ecosystem.yml's job list only, so
  # `watcher:` adds it where it really runs.
  def jobs_json(detect:, gate:, watcher: false)
    job = gate == 'failure' ? 'failure' : 'success'
    steps = [{ 'name' => 'Set up job', 'conclusion' => 'success' },
             { 'name' => 'run the gate', 'conclusion' => gate },
             { 'name' => 'Complete job', 'conclusion' => 'success' }]

    jobs = [{ 'name' => 'detect changed paths', 'conclusion' => detect },
            { 'name' => 'test + coverage (latest ruby/rails)', 'conclusion' => job, 'steps' => steps },
            { 'name' => 'lint (rubocop)', 'conclusion' => job, 'steps' => steps }]
    jobs << { 'name' => 'sidekiq release watcher', 'conclusion' => 'skipped', 'steps' => [] } if watcher

    JSON.generate('total_count' => jobs.size, 'jobs' => jobs)
  end

  # The job list a FAILED `detect` leaves behind: `needs:` skips every
  # dependent before it starts, so the gated jobs report `skipped` and carry
  # no steps at all.
  def jobs_json_after_failed_detect
    jobs = [{ 'name' => 'detect changed paths', 'conclusion' => 'failure' },
            { 'name' => 'test + coverage (latest ruby/rails)', 'conclusion' => 'skipped', 'steps' => [] },
            { 'name' => 'lint (rubocop)', 'conclusion' => 'skipped', 'steps' => [] },
            { 'name' => 'sidekiq release watcher', 'conclusion' => 'skipped', 'steps' => [] }]

    JSON.generate('total_count' => jobs.size, 'jobs' => jobs)
  end

  # A job list carrying no gated job at all — the detect job alone. There is
  # no evidence of execution in it, so the row must not certify the run on
  # its conclusion alone. `watcher` adds ecosystem.yml's schedule-only job:
  # row 14 excludes it by name, so a lane carrying it and the detect job
  # still carries no gated job.
  def jobs_json_without_gated_jobs(detect:, watcher: false)
    jobs = [{ 'name' => 'detect changed paths', 'conclusion' => detect }]
    jobs << { 'name' => 'sidekiq release watcher', 'conclusion' => 'skipped', 'steps' => [] } if watcher

    JSON.generate('total_count' => jobs.size, 'jobs' => jobs)
  end

  # release.yml's job list, not the detect/lint shape: the `preflight` cheap
  # gate, the `release` job gated on `needs.preflight.outputs.proceed`, and the
  # `demo` job that needs both (release.yml:222). The names are the ones the
  # workflow declares — `demo` is the caller job's own key, a reusable-workflow
  # call, not a slash-joined "demo / deploy-demo". A `nil` conclusion is a job
  # that exists and has not concluded yet — what a run still executing looks
  # like.
  def release_jobs_json(preflight:, release:, demo:)
    jobs = [{ 'name' => 'preflight', 'conclusion' => preflight },
            { 'name' => 'release', 'conclusion' => release },
            { 'name' => 'demo', 'conclusion' => demo }]

    JSON.generate('total_count' => jobs.size, 'jobs' => jobs)
  end

  # deploy-demo.yml's job list — the `authorize` allowlist job and the `build`
  # job whose steps do the actual work. Real jobs API shape: step objects carry
  # name/status/conclusion/number/timestamps only — NO `log` field. The log is
  # read separately via `gh run view <id> --job <id> --log` (see stub below);
  # row 12 feeds each test's log content in via the `log:` fixture instead of
  # inventing a `log` key on the step that the real API would never return.
  def demo_jobs_json
    jobs = [{ 'name' => 'authorize', 'conclusion' => 'success', 'steps' => [] },
            { 'name' => 'build', 'id' => 9999, 'conclusion' => 'success',
              'steps' => [{ 'name' => 'Set up job', 'conclusion' => 'success' },
                          { 'name' => 'resolve built commit', 'conclusion' => 'success' },
                          { 'name' => 'verify pushed tags resolve', 'conclusion' => 'success' }] }]

    JSON.generate('total_count' => jobs.size, 'jobs' => jobs)
  end

  # `gh run view <id> --job <id> --log` prints one tab-separated line per log
  # line: `<job>\t<step>\t<timestamp> <message>` — the job and step names are
  # columns ahead of the log line's own timestamp and text, which share one.
  # Row 12 picks the step out of field 2, so the fixture has to carry that
  # shape — a bare message column, or a timestamp in front of the step, is not
  # what `gh` prints.
  def log_lines(step, messages)
    messages.map { |message| "build\t#{step}\t2026-01-01T00:00:00.0000000Z #{message}" }
  end

  # What the `resolve built commit` step's log looks like: the shell that writes
  # `sha=` and `short=sha-<7>` to $GITHUB_OUTPUT is echoed into the job log, so
  # the tag is recoverable only by reading the log text (deploy-demo.yml:173-180).
  # A nil `short` is the regression the comment there records: the step ran and
  # wrote no tag Image Updater's ^sha-[0-9a-f]{7}$ can select. `decoys` add lines
  # belonging to OTHER steps of the same `build` job: a `sha-<7>`-shaped string
  # over there is not the tag this step resolved.
  def resolve_log(short:, decoys: {})
    lines = log_lines(RESOLVE_STEP,
                      ['Run git rev-parse HEAD',
                       '  7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7',
                       'Run {',
                       '    echo "sha=$sha"',
                       "    echo \"short=#{short}\"",
                       '  } >> "$GITHUB_OUTPUT"'])

    decoys.each { |step, messages| lines.concat log_lines(step, messages) }

    "#{lines.join("\n")}\n"
  end

  # One `CheckRun` entry exactly as `gh pr list --json statusCheckRollup` emits
  # it. The rollup is the GraphQL union `StatusCheckRollupContext`, so it
  # arrives as a LIST of these and of `status_context` entries — never as an
  # object carrying a `.state` on the PR itself.
  def check_run(conclusion, status: 'COMPLETED', name: 'test + coverage (latest ruby/rails)',
                workflow: 'CI')
    entry = { '__typename' => 'CheckRun', 'name' => name, 'status' => status,
              'conclusion' => conclusion, 'workflowName' => workflow,
              'startedAt' => '2026-01-01T00:00:00Z',
              'detailsUrl' => 'https://github.com/wurk-owner/wurk/actions/runs/1' }
    entry['completedAt'] = '2026-01-01T00:04:12Z' if status == 'COMPLETED'
    entry
  end

  # Actions sends `conclusion: null` while a job runs — the shape the rollup has
  # to read as PENDING rather than as a missing verdict.
  def running_check_run(name: 'lint (rubocop)')
    check_run(nil, status: 'IN_PROGRESS', name: name)
  end

  # A check from an app outside Actions: the other half of the union, carrying
  # `state` and no conclusion.
  def status_context(state, context: 'verify')
    { '__typename' => 'StatusContext', 'context' => context, 'state' => state,
      'targetUrl' => 'https://example.test/checks/1' }
  end

  # A dependabot PR shaped like the one `gh pr list --json number,title,
  # createdAt,headRefName,updatedAt,statusCheckRollup,headRefOid` emits.
  # `branch:` is the dependabot branch (`dependabot/<ecosystem>/...`), left
  # out when the fixture is title-only — that shape exercises the fallback
  # to the title. `age_days:` is how long ago the PR was opened (the age a
  # budget is graded against) and `updated_days:` how long ago it was last
  # updated (reported, never graded).
  def dependabot_pr(number:, title:, age_days:, branch: nil, sha: nil,
                    updated_days: nil, updated_at: nil, rollup: nil)
    now = Time.now.utc

    pr = {
      'number' => number,
      'title' => title,
      'createdAt' => (now - (age_days * 86_400)).iso8601,
      'updatedAt' => updated_at || (now - ((updated_days || age_days) * 86_400)).iso8601,
      'statusCheckRollup' => rollup || [check_run('FAILURE')]
    }
    pr['headRefName'] = branch if branch
    pr['headRefOid'] = sha if sha
    pr
  end

  def write_fixture(dir, name, body)
    File.write(File.join(dir, name), body)
  end

  # The run list's SHAPE for one workflow: :default writes no fixture (the
  # stub serves the four-fixture run), :empty serves a readable `[]`, :fail
  # serves nothing at all (the rate-limit / 4xx shape), and 'error-empty' /
  # 'error-run' emit their bytes and THEN exit non-zero — the half-failed
  # read a row can only catch by checking gh's exit status.
  def write_runs_fixture(dir, workflow, mode)
    return if mode == :default

    write_fixture(dir, "#{workflow}.runs", mode.to_s)
  end

  # The version this checkout expects — the same extraction shape the brief's
  # command uses, so the test and the row compare the same value.
  def checkout_version
    File.read(File.join(ROOT, 'lib', 'wurk', 'version.rb'))[/VERSION = '([^']+)'/, 1]
  end

  # The `Command` cell of the row whose Signal cell contains `signal`. Cells
  # are `|`-separated and the commands are full of shell pipes, so the cell is
  # cut at its backticks instead: the command opens at the last backtick before
  # its own `gh_command` token and closes at the next one after it. `\|` is
  # markdown's escape for a literal pipe inside a cell. `gh_command` defaults
  # to `gh run list` for the run-list rows; row 15 grades dependabot via
  # `gh pr list`, so it asks for that token explicitly.
  def command_cell(signal, gh_command: 'gh run list')
    row = @text.lines.find { |line| line.include?(signal) && line.include?(gh_command) }
    raise "health.md has no row for #{signal.inspect} that calls `#{gh_command}`" if row.nil?

    open_at = row.rindex('`', row.index(gh_command))
    raise "no opening backtick before `#{gh_command}` on the #{signal.inspect} row" if open_at.nil?

    close_at = row.index('`', open_at + 1)
    raise "no closing backtick for the Command cell on the #{signal.inspect} row" if close_at.nil?

    row[(open_at + 1)...close_at].gsub('\\|', '|')
  end

  # The brief's filing paragraph — the one saying when a signal files an ask
  # and how the open-issue dedupe runs. One paragraph, so a title assertion
  # cannot be satisfied by a mention somewhere else in the file. It reads a
  # GIVEN brief text, so a mutation test can feed the guard a broken copy.
  def filing_paragraph(text = @text)
    para = text.split(/\n\s*\n/).find { |candidate| candidate.include?('file one ask') }
    raise 'health.md has no filing paragraph saying when to file one ask' if para.nil?

    para
  end

  # ONE guard for the six per-form ask titles: the filing paragraph must carry
  # the title EXACTLY as its row files it, and no title may carry a resolved
  # run-to-run value — the dedupe match is exact equality, so such a title can
  # never hit an open ask and the same ask is re-filed on every checkup. It
  # reads the brief TEXT, so the six positive assertions and the six mutation
  # tests exercise the SAME rule: a mutation test written against a second
  # spelling of it would prove nothing about the guard.
  def assert_filing_ask_title(text, title, resolved: nil)
    para = filing_paragraph(text)

    assert_includes para, title,
                    'the dedupe match is exact equality on the title, so every signal must ' \
                    "file under one stable name; the filing paragraph is missing #{title}"

    return if resolved.nil?

    refute_match(resolved, para,
                 "a resolved value inside #{title} can never match an open ask, so the ask " \
                 'is re-filed on every checkup')
  end

  # The resolved-value half of the ask-title guard: a title carrying a value
  # that changes run to run can never match an open ask, so the same ask is
  # re-filed on every checkup. The copy keeps the PLACEHOLDER title and adds
  # the RESOLVED variant, so the guard cannot pass by failing earlier on the
  # missing title — the resolved value is all that is left to refuse.
  def assert_resolved_ask_title_rejected(title, resolved:, resolved_title:)
    text = @text.sub(title, "#{title} #{resolved_title}")

    refute_equal @text, text,
                 'the mutation must have landed before the guard is exercised'

    para = filing_paragraph(text)

    assert_includes para, title,
                    'the copy must keep the placeholder title, so the guard fails on the ' \
                    'resolved value and not on the missing title'

    assert_includes para, resolved_title,
                    'the copy must carry the resolved variant, so the guard has a resolved ' \
                    'value to refuse'

    error = assert_raises(Minitest::Assertion) do
      assert_filing_ask_title(text, title, resolved: resolved)
    end

    assert_includes error.message, 'a resolved value inside',
                    'the guard must fail BECAUSE the title carries a resolved value'
  end

  # The backticked issues lookup the filing paragraph requires before any ask
  # is filed — the dedupe guard's executable core, extracted so the tests can
  # RUN it rather than trust its spelling.
  def lookup_command
    command = @text[/`([^`]*issues\?state=open[^`]*)`/, 1]
    raise 'health.md carries no backticked issues?state=open lookup' if command.nil?

    command
  end

  # The demo served-version row's command cell. It calls `curl`, not `gh`, so
  # it is located by its own signal text and the backticked command span.
  def served_version_command
    row = @text.lines.find { |line| line.include?('the demo serves the checkout version') }
    raise 'health.md has no served-version row' if row.nil?

    open_at = row.index('`')
    close_at = row.index('`', open_at + 1)
    raise 'the served-version row has no backticked Command cell' if open_at.nil? || close_at.nil?

    row[(open_at + 1)...close_at].gsub('\\|', '|')
  end

  # Runs the served-version row as a stand-alone bash script with a stub curl
  # first on PATH. The stub serves a JSON body and an HTTP status; `curl_exit`
  # simulates a transport failure. No network access, no credentials.
  def run_served_version_row(body:, http_status: 200, curl_exit: 0)
    Dir.mktmpdir('wurk-health-served-version-') do |tmpdir|
      bin_dir = File.join(tmpdir, 'bin')
      Dir.mkdir(bin_dir)

      curl_path = File.join(bin_dir, 'curl')
      File.write(curl_path, STUB_CURL)
      File.chmod(0o755, curl_path)

      script_path = File.join(tmpdir, 'served-version.sh')
      File.write(script_path, "#!/usr/bin/env bash\n#{served_version_command}\n")
      File.chmod(0o755, script_path)

      env = {
        'PATH' => "#{bin_dir}:#{ENV.fetch('PATH', '')}",
        'WURK_TEST_CURL_BODY' => body.to_s,
        'WURK_TEST_CURL_STATUS' => http_status.to_s,
        'WURK_TEST_CURL_EXIT' => curl_exit.to_s
      }

      Open3.capture3(env, script_path, chdir: ROOT)
    end
  end

  # Row 8's command. `runs:` drives the run list's SHAPE: :default serves
  # the four-fixture run, :empty serves a readable `[]`, :fail serves nothing
  # (the rate-limit / 4xx shape), and 'error-empty'/'error-run' emit their
  # bytes and then exit non-zero — the half-failed read. The jobs list is
  # written either way, so only the run-list read changes.
  def run_row8(jobs:, conclusion:, sha:, jobs_fail: false, runs: :default)
    run_command(command_cell('`main` is green'), jobs_fail: jobs_fail) do |fixtures|
      write_runs_fixture(fixtures, 'test.yml', runs)
      write_fixture(fixtures, 'test.yml.dbid', '1')
      write_fixture(fixtures, 'test.yml.sha', sha)
      write_fixture(fixtures, 'test.yml.conclusion', conclusion)
      write_fixture(fixtures, 'test.yml.url', URL_TEST)
      write_fixture(fixtures, 'dbid-1.jobs', jobs)
    end
  end

  # A lib/wurk/version.rb body carrying `version` — the shape the stubbed
  # contents API serves for the version-carrying commit, and the working
  # tree the stale-checkout shape runs from.
  def version_rb_content(version)
    <<~RUBY
      # frozen_string_literal: true

      module Wurk
        VERSION = '#{version}'
      end
    RUBY
  end

  # Row 9's command. The fixtures put version 9.9.9 AT the resolved commit
  # (the stubbed contents API serves it) while this checkout carries its own
  # older VERSION — deliberately, so every verdict assertion below only
  # passes for a row that grades the commit's version. `version_at_head:
  # nil` serves no fixture, so the contents read fails the way a rate limit
  # or a 4xx would. `stale_version:` runs the command from a directory whose
  # lib/wurk/version.rb carries that older version — the stale-checkout
  # shape. `cell:` lets a test run a mutated cell.
  def run_row9(jobs:, conclusion:, sha:, jobs_fail: false, version_sha: nil,
               http_status: '200', version_at_head: version_rb_content('9.9.9'),
               probe_version: '9.9.9', stale_version: nil, cell: nil, runs: nil)
    cell ||= command_cell('the last release published')

    if stale_version
      Dir.mktmpdir('wurk-stale-checkout-') do |stale|
        FileUtils.mkdir_p(File.join(stale, 'lib', 'wurk'))
        File.write(File.join(stale, 'lib', 'wurk', 'version.rb'), version_rb_content(stale_version))

        run_command(cell, jobs_fail: jobs_fail, http_status: http_status, chdir: stale) do |fixtures|
          write_runs_fixture(fixtures, 'release.yml', runs)
          write_row9_fixtures(fixtures, conclusion: conclusion, jobs: jobs, sha: sha,
                                        version_sha: version_sha, version_at_head: version_at_head,
                                        probe_version: probe_version, runs: runs)
        end
      end
    else
      run_command(cell, jobs_fail: jobs_fail, http_status: http_status) do |fixtures|
        write_runs_fixture(fixtures, 'release.yml', runs)
        write_row9_fixtures(fixtures, conclusion: conclusion, jobs: jobs, sha: sha,
                                      version_sha: version_sha, version_at_head: version_at_head,
                                      probe_version: probe_version, runs: runs)
      end
    end
  end

  def write_row9_fixtures(fixtures, conclusion:, jobs:, sha:, version_sha:, version_at_head:,
                          probe_version:, runs: nil)
    runs ||= [{ headBranch: 'main', event: 'push', headSha: sha,
                databaseId: 201, conclusion: conclusion, url: URL_RELEASE }]
    write_fixture(fixtures, 'release-runs.json', JSON.generate(runs))
    write_fixture(fixtures, 'release.yml.dbid', '201')
    write_fixture(fixtures, 'release.yml.sha', sha)
    write_fixture(fixtures, 'release.yml.conclusion', conclusion)
    write_fixture(fixtures, 'release.yml.url', URL_RELEASE)
    # The commit that carries Wurk::VERSION: the release run the row is
    # allowed to grade is the one bound to it.
    write_fixture(fixtures, 'version-head.sha', version_sha || sha)
    write_fixture(fixtures, 'dbid-201.jobs', jobs)
    write_fixture(fixtures, 'version-at-head.rb', version_at_head) if version_at_head
    # The one version STUB_CURL serves the configured HTTP status for.
    write_fixture(fixtures, 'probe.version', probe_version)
  end

  # Row 11's command, run against a stub `gh` that serves the Latest
  # GitHub Release from a fixture. `release: nil` writes no fixture, so the
  # lookup fails the way a rate limit or a 4xx would.
  def run_row_release_artifact(author: 'github-actions[bot]',
                               assets: [{ 'name' => 'wurk-1.9.0.gem' }], release: :default)
    body = release == :default ? JSON.generate('author' => { 'login' => author }, 'assets' => assets) : nil

    run_command(command_cell('the GitHub Release carries the gem', gh_command: 'gh release view'),
                jobs_fail: false) do |fixtures|
      write_fixture(fixtures, 'release.json', body) if body
    end
  end

  # Row 12's command. `runs:` drives the run list's SHAPE: :default serves
  # the four-fixture run, :empty serves a readable `[]`, :fail serves nothing
  # (the rate-limit / 4xx shape), and 'error-empty'/'error-run' emit their
  # bytes and then exit non-zero — the half-failed read.
  def run_row12(jobs:, log:, conclusion:, sha:, jobs_fail: false, log_fail: false, runs: :default)
    run_command(command_cell('the demo deployed'), jobs_fail: jobs_fail, log_fail: log_fail) do |fixtures|
      write_runs_fixture(fixtures, 'deploy-demo.yml', runs)
      write_fixture(fixtures, 'deploy-demo.yml.dbid', '301')
      write_fixture(fixtures, 'deploy-demo.yml.sha', sha)
      write_fixture(fixtures, 'deploy-demo.yml.conclusion', conclusion)
      write_fixture(fixtures, 'deploy-demo.yml.url', URL_DEMO)
      write_fixture(fixtures, 'dbid-301.jobs', jobs)
      write_fixture(fixtures, 'dbid-301.job-9999.log', log)
    end
  end

  # Row 14's command — the same read over both lanes. `runs:` drives the run
  # list's SHAPE per lane: a single mode (:default, :empty, :fail,
  # 'error-empty', 'error-run') applies to both, a Hash keyed by workflow sets
  # each lane's shape on its own, so one lane can be empty while the other
  # still grades. `topology:` and
  # `ecosystem:` override a lane's job-list fixture.
  def run_row14(jobs_fail: false, runs: :default, topology: nil, ecosystem: nil)
    modes = runs.is_a?(Hash) ? runs : { 'topology.yml' => runs, 'ecosystem.yml' => runs }

    run_command(command_cell('topology and ecosystem lanes'), jobs_fail: jobs_fail) do |fixtures|
      write_runs_fixture(fixtures, 'topology.yml', modes.fetch('topology.yml', :default))
      write_runs_fixture(fixtures, 'ecosystem.yml', modes.fetch('ecosystem.yml', :default))
      write_fixture(fixtures, 'topology.yml.dbid', '101')
      write_fixture(fixtures, 'topology.yml.sha', SHA_TOPOLOGY)
      write_fixture(fixtures, 'topology.yml.conclusion', 'success')
      write_fixture(fixtures, 'topology.yml.url', URL_TOPOLOGY)
      write_fixture(fixtures, 'dbid-101.jobs', topology || jobs_json(detect: 'success', gate: 'skipped'))

      write_fixture(fixtures, 'ecosystem.yml.dbid', '102')
      write_fixture(fixtures, 'ecosystem.yml.sha', SHA_ECOSYSTEM)
      write_fixture(fixtures, 'ecosystem.yml.conclusion', 'success')
      write_fixture(fixtures, 'ecosystem.yml.url', URL_ECOSYSTEM)
      ecosystem_jobs = ecosystem || jobs_json(detect: 'success', gate: 'success', watcher: true)
      write_fixture(fixtures, 'dbid-102.jobs', ecosystem_jobs)
    end
  end

  # Row 15 grades dependabot PRs against per-ecosystem budgets derived from
  # dependabot.yml (28d bundler, 14d bun, 37d github-actions, 37d docker) and
  # REPORTS what it read: a summary line, one line per open PR, and one
  # `Unhealthy:` line per red PR past its budget — `Docker bump #<n> is
  # waiting on us` for a docker bump whose title matches the bun-pin shape
  # AND whose head still carries an outstanding pin mismatch, `Dependabot is
  # stuck on #<n>` otherwise. The stub `gh` answers
  # `gh pr list --state open --app dependabot --json ...` from
  # $WURK_TEST_FIXTURES/dependabot.prs, so the command runs against fixed
  # fixtures instead of the API — fixtures shaped like the list `gh` really
  # emits, rollup included. `prs: nil` writes no fixture at all, so the read
  # fails the way a rate limit or a 4xx would. `cell:` lets a test run a
  # mutated cell. `pins:` drives what the row's five pin-site contents reads
  # return for a waiting-shaped candidate: :mismatch is the dependabot-only
  # head (the Dockerfile bumped, every other site still on BUN_OLD) and the
  #   default, since that is the state every candidate starts in; :agree is the
  #   head after the pin edits landed; :error_body makes every pin read emit a
  #   nonempty JSON error body and exit non-zero — the half-failed shape a real
  #   404 or rate limit produces; a Hash sets sites individually, a String
  # version or nil to drop that site's fixture so its read fails; nil serves
  # nothing, so every pin read fails like a 4xx. The stub serves the pins
  # only at the head sha the fixture names — the candidate's own headRefOid.
  # `runs:` serves the second read the docker pin carve-out depends on — the
  # failing CI JOB's OWN log — keyed by the PR's head sha: `gh run list
  # --workflow test.yml --commit <sha>` names the failed run, the run's job
  # list names the `test + coverage (latest ruby/rails)` job inside it, and
  # `gh run view <id> --job <job id> --log-failed` reads that job's failing
  # output. A nil value writes no fixture, so the read is unreadable and the
  # row must fail closed; a head with NO entry in `runs:` gets a READABLE run
  # list carrying no failed run — the shape that sends the row past the step-5
  # discriminator to the step-6 head-pins verification. `jobs_fail` breaks the
  # run's JOB LIST read — the second of the three reads — so the row must fail
  # closed on an unreadable job list too. `parity:` / `lint:` set the SIBLING
  # jobs' conclusions in that job list; they default to `success`, because the
  # pins-only happy path is the expected-red shape only when the run's OTHER
  # jobs are clean — a red sibling is a second red check the rollup already
  # counts, and the row must grade the PR stuck instead of clearing it.
  def run_row15(prs:, jobs_fail: false, cell: nil, pins: :mismatch, runs: {},
                parity: 'success', lint: 'success')
    cell ||= command_cell('Dependabot is not stuck', gh_command: 'gh pr list')

    run_command(cell, jobs_fail: jobs_fail) do |fixtures|
      write_fixture(fixtures, 'dependabot.prs', JSON.generate(prs)) if prs
      write_pin_fixtures(fixtures, prs, pins)
      runs.each_with_index do |(sha, log), index|
        dbid = 9001 + index
        job_id = 9101 + index
        write_fixture(fixtures, "commit-#{sha}.runs",
                      JSON.generate([{ 'databaseId' => dbid, 'conclusion' => 'failure' }]))
        write_fixture(fixtures, "dbid-#{dbid}.jobs", ci_jobs_json(job_id, parity: parity, lint: lint))
        write_fixture(fixtures, "dbid-#{dbid}.job-#{job_id}.log-failed", log) if log
        # The run-level aggregate `gh run view <id> --log-failed` prints
        # WITHOUT --job: every failed job of the run in one log. It names a
        # DIFFERENT test file on purpose, so a brief that dropped the
        # --job binding reads it and grades the pins-only PR as stuck —
        # the binding stays falsifiable instead of merely documented.
        aggregate = failed_run_log(
          'Failure: test_a_sibling_job_failure [test/unit/sibling_job_test.rb:12]:'
        )
        write_fixture(fixtures, "dbid-#{dbid}.log-failed", aggregate) if log
      end
      # A head with no `runs:` entry gets a READABLE run list carrying no
      # failed test.yml run for the head: the discriminator read succeeds and
      # finds nothing to grade, which is the shape that sends a bun-pin-shaped
      # candidate to the head-pins verification. A head WITH an entry keeps
      # what that entry wrote — including the failed run a nil log leaves
      # unreadable, which must stay a failed-closed discriminator read.
      Array(prs).filter_map { |pr| pr['headRefOid'] }.uniq.each do |head|
        next if runs.key?(head)

        write_fixture(fixtures, "commit-#{head}.runs", "[]\n")
      end
    end
  end

  # The bun pin sites row 15 reads at a candidate PR's head, and the head the
  # stub serves them at. Site keys are the repo-relative paths the row reads;
  # fixture names map `/` to `_` exactly as the stub does.
  def write_pin_fixtures(dir, prs, pins)
    head = Array(prs).filter_map { |pr| pr['headRefOid'] }.first
    write_fixture(dir, 'pin.head.sha', head) if head
    return if pins.nil?

    pin_fixture_versions(pins).each do |site, version|
      next if version.nil?

      if version == :error
        write_fixture(dir, "pin.#{site.tr('/', '_')}.error", "#{PIN_ERROR_BODY}\n")
      else
        write_fixture(dir, "pin.#{site.tr('/', '_')}", pin_site_content(site, version))
      end
    end
  end

  # :mismatch is the dependabot-only head — the Dockerfile bumped, every
  # other site still on BUN_OLD. :agree is the head after the pin edits
  # landed. :error_body makes every site's read emit PIN_ERROR_BODY and exit
  # non-zero — the shape a real 404 or rate limit leaves on stdout. A Hash
  # overrides single sites on top of BUN_OLD; a nil value drops that site's
  # fixture so its read fails silently, and an `:error` value makes that one
  # read emit the error body and fail like a 4xx while the others serve.
  def pin_fixture_versions(pins)
    versions = { 'Dockerfile' => BUN_OLD, 'mise.toml' => BUN_OLD,
                 'docs/deployment.md' => BUN_OLD,
                 '.github/workflows/test.yml' => BUN_OLD,
                 '.github/workflows/release.yml' => BUN_OLD }
    case pins
    when :agree
      versions.transform_values! { |_old| BUN_NEW }
    when :mismatch
      versions['Dockerfile'] = BUN_NEW
    when :error_body
      versions.transform_values! { :error }
    when Hash
      versions.merge!(pins)
    end
    versions
  end

  # The five pin sites' shapes, as toolchain_pins_test.rb reads them:
  # `FROM oven/bun:<v>-slim` at line start in the Dockerfile and the
  # deployment doc, `bun = "<v>"` in mise.toml, and a quoted `bun-version:`
  # input in each workflow — the shapes the row's extraction has to parse.
  def pin_site_content(site, version)
    case site
    when 'Dockerfile', 'docs/deployment.md'
      "FROM ruby:3.4-slim-bookworm\nFROM oven/bun:#{version}-slim AS spa\n"
    when 'mise.toml'
      "[tools]\nnode = \"24\"\nbun = \"#{version}\"\n"
    else
      "steps:\n  - uses: oven-sh/setup-bun@v2\n    with:\n      bun-version: \"#{version}\"\n"
    end
  end

  # The job list of the CI run the docker pin discriminator reads: the
  # `test + coverage (latest ruby/rails)` job the pins assertion runs in
  # (carrying the `id` `gh run view --job` takes) beside the run's other
  # jobs. The row picks the pins job BY NAME, so a run that renamed it
  # finds no job and fails closed. `parity:` / `lint:` set the SIBLING
  # jobs' conclusions; they default to `success` — the carve-out fires
  # only when the pins assertion is the run's ONLY red check, so the
  # pins-only shape a test expects to clear the PR needs clean siblings,
  # and a red sibling is the unrelated-red shape that must stay stuck.
  def ci_jobs_json(job_id, parity: 'success', lint: 'success')
    jobs = [
      { 'id' => job_id, 'name' => 'test + coverage (latest ruby/rails)',
        'conclusion' => 'failure', 'steps' => [] },
      { 'id' => job_id + 1, 'name' => 'parity (oracle)',
        'conclusion' => parity, 'steps' => [] },
      { 'id' => job_id + 2, 'name' => 'lint (rubocop)',
        'conclusion' => lint, 'steps' => [] }
    ]
    JSON.generate('total_count' => jobs.size, 'jobs' => jobs)
  end

  # The failing CI JOB's log — what `gh run view <id> --job <job id>
  # --log-failed` prints. The discriminator reads the FAILING TEST FILE out
  # of it, so the fixture has to carry minitest's own failure line
  # (`Failure: test_x [test/unit/<file>_test.rb:<line>]:`); the rollup
  # alone never can.
  def failed_run_log(*lines)
    "#{lines.join("\n")}\n"
  end

  # Runs a brief command as a stand-alone Bash script with a stub `gh` first
  # on PATH. The script is NOT prefixed with `set -euo pipefail` — the brief
  # enables no shell options, and injecting them would mask a regression that
  # swallows the failing `gh api` inside a pipeline. Yields the fixtures dir
  # before the script runs so the caller can write the job lists the stub
  # serves, then returns Open3's [stdout, stderr, status].
  def run_command(command, jobs_fail:, log_fail: false, http_status: '200', chdir: ROOT)
    Dir.mktmpdir('wurk-health-brief-') do |tmpdir|
      fixtures = File.join(tmpdir, 'fixtures')
      bin_dir = File.join(tmpdir, 'bin')
      Dir.mkdir(fixtures)
      Dir.mkdir(bin_dir)

      yield fixtures

      { 'gh' => STUB_GH, 'curl' => STUB_CURL }.each do |name, body|
        path = File.join(bin_dir, name)
        File.write(path, body)
        File.chmod(0o755, path)
      end

      script_path = File.join(tmpdir, 'health.sh')
      File.write(script_path, "#!/usr/bin/env bash\n#{command}\n")
      File.chmod(0o755, script_path)

      env = {
        'PATH' => "#{bin_dir}:#{ENV.fetch('PATH', '')}",
        'WURK_TEST_FIXTURES' => fixtures,
        'WURK_TEST_JOBS_FAIL' => jobs_fail ? '1' : '0',
        'WURK_TEST_LOG_FAIL' => log_fail ? '1' : '0',
        'WURK_TEST_HTTP_STATUS' => http_status.to_s
      }

      # The extracted cells run from the checkout root, the way the brief's
      # commands run in the checkup lane; the stale-checkout shape passes
      # the directory that holds its own working tree.
      Open3.capture3(env, script_path, chdir: chdir)
    end
  end

  # Stub `gh`. Every answer is read from the fixture dir the test wrote, so
  # the brief's command runs against a fixed jobs list instead of the API.
  # The run list also serves `url`, from a per-workflow `<wf>.url` fixture and
  # falling back to a run-URL derived from the databaseId — the brief asks for
  # `url` by name, so a stub that dropped it would hand the row a literal
  # `null` and let a broken row pass.
  # The issues lookup is answered BEFORE the failure gate below: it is not the
  # jobs call, and jobs-fail mode exists to break exactly one call, not the
  # dedupe lookup beside it.
  # `WURK_TEST_JOBS_FAIL=1` makes ONLY the jobs call fail, leaving the run
  # list readable — that is the exact shape of the false green this file
  # pins: a `conclusion` the brief can see, and a jobs list it cannot.
  # `WURK_TEST_LOG_FAIL=1` is the analog for row 12's `gh run view --log`
  # read — jobs readable, log unreadable, and the row must still fail
  # closed as `verdict unknown <sha>`.
  # The run list has four extra fixture-driven shapes, written per workflow
  # as a `<wf>.runs` fixture holding `empty`, `fail`, `error-empty` or
  # `error-run`:
  #   * `empty` serves `[]` and exits 0 — a READABLE list with no run in it.
  #     The row must name that outcome (`no run: <workflow> has no matching
  #     run`) rather than extract `null` fields off it.
  #   * `fail` writes nothing to stdout and exits non-zero — an UNREADABLE
  #     list (a rate limit, a 4xx). The row must say the list was not
  #     readable, never grade a colour off it.
  #   * `error-empty` serves `[]` and THEN exits non-zero — a read that
  #     failed after its bytes had already landed on stdout. Only a row that
  #     captured and checked gh's exit status grades it `verdict unknown`;
  #     one that inspected the array alone prints the named `no run:` outcome
  #     for a read that failed.
  #   * `error-run` serves the four-fixture list and THEN exits non-zero —
  #     the same half-failed read with a run in it, which a row that ignored
  #     the exit status would grade as a verdict the failed read never earned.
  # With no `<wf>.runs` fixture the four-fixture path below is unchanged.
  STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    fixdir="$WURK_TEST_FIXTURES"
    case "${1:-}" in
      run)
        case "${2:-}" in
          view)
            # `gh run view <dbid> --job <jobid> --log` is how row 12 reads the
            # `resolve built commit` step's log; the jobs API carries no step
            # logs, so the row has to fetch them separately. Args: run id is
            # the first non-flag arg, the job id is the arg after `--job`.
            # `gh run view <dbid> --job <jobid> --log-failed` is the THIRD read
            # row 15's docker pin carve-out depends on: the failing CI JOB's
            # own output, which is the only place the failing TEST FILE is
            # named. It is JOB-BOUND: a run-level `--log-failed` (no --job)
            # mixes every failed job of the run into one log, so a sibling
            # job's failure would name a second test file and the carve-out
            # could never fire. The unbound form is served from its own
            # fixture, so a brief that dropped the --job binding reads
            # DIFFERENT (aggregate) output and fails the row's own assertions
            # instead of quietly passing.
            if [ "$WURK_TEST_LOG_FAIL" = "1" ]; then
              printf 'stub gh run view --log: the log read fails on purpose (rate limited or 4xx)\n' >&2
              exit 1
            fi
            prev=""
            dbid=""
            jobid=""
            want_log=""
            want_failed=""
            for arg in "$@"; do
              case "$prev" in
                --job) jobid="$arg" ;;
              esac
              case "$arg" in
                --log) want_log="1" ;;
                --log-failed) want_failed="1" ;;
                [0-9]*)
                  if [ -z "$dbid" ] && [ "$arg" != "$prev" ]; then
                    dbid="$arg"
                  fi
                  ;;
              esac
              prev="$arg"
            done
            if [ -z "$want_log" ] && [ -z "$want_failed" ]; then
              printf 'stub gh run view: only the --log and --log-failed forms are stubbed here, got: %s\n' "$*" >&2
              exit 1
            fi
            if [ -n "$want_failed" ]; then
              if [ -z "$dbid" ]; then
                printf 'stub gh run view --log-failed: need a run id, got: %s\n' "$*" >&2
                exit 1
              fi
              if [ -n "$jobid" ]; then
                fixture="$fixdir/dbid-$dbid.job-$jobid.log-failed"
              else
                fixture="$fixdir/dbid-$dbid.log-failed"
              fi
              if [ ! -s "$fixture" ]; then
                printf 'stub gh run view --log-failed: no failed-log fixture for run %s job %s (looked for %s)\n' \
                  "$dbid" "$jobid" "$fixture" >&2
                exit 1
              fi
              cat "$fixture"
              exit 0
            fi
            if [ -z "$dbid" ] || [ -z "$jobid" ]; then
              printf 'stub gh run view --log: need a run id and a --job id, got: %s\n' "$*" >&2
              exit 1
            fi
            fixture="$fixdir/dbid-$dbid.job-$jobid.log"
            if [ ! -s "$fixture" ]; then
              printf 'stub gh run view --log: no log fixture for run %s job %s (looked for %s)\n' \
                "$dbid" "$jobid" "$fixture" >&2
              exit 1
            fi
            cat "$fixture"
            ;;
          *)
            wf=""
            commit=""
            json=""
            branch=""
            event=""
            prev=""
            for arg in "$@"; do
              case "$arg" in
                *.yml) wf="$arg" ;;
              esac
              case "$prev" in
                --commit) commit="$arg" ;;
                --json) json="$arg" ;;
                --branch) branch="$arg" ;;
                --event) event="$arg" ;;
              esac
              prev="$arg"
            done
            # Row 15's docker pin discriminator read: `gh run list --workflow
            # test.yml --commit <head sha> --json databaseId,conclusion`
            # names the PR's failing CI run, whose `test + coverage (latest
            # ruby/rails)` job's failed log the row reads next. It is
            # COMMIT-BOUND: a read without --commit would name some other run,
            # and one PR's failing run must never grade another PR, so the
            # stub refuses the request instead of serving a fixture. It is
            # WORKFLOW-BOUND too: `bench.yml` and `topology.yml` also fire on
            # pull_request, so an unfiltered read takes the first failed run
            # for the commit across ALL of them - a run whose failed output
            # names no Ruby test file at all, which can never clear the
            # carve-out. The stub refuses the unbound request too, so a brief
            # that dropped the filter fails closed.
            if [ "$json" = "databaseId,conclusion" ]; then
              if [ -z "$commit" ]; then
                printf 'stub gh run list: the docker pin discriminator read is commit-bound, refusing a request without --commit: %s\n' "$*" >&2
                exit 1
              fi
              if [ "$wf" != "test.yml" ]; then
                printf 'stub gh run list: the docker pin discriminator read is workflow-bound to test.yml, refusing a request for %s: %s\n' "${wf:-<none>}" "$*" >&2
                exit 1
              fi
              fixture="$fixdir/commit-$commit.runs"
              if [ ! -s "$fixture" ]; then
                printf 'stub gh run list: no runs fixture for commit %s (looked for %s)\n' "$commit" "$fixture" >&2
                exit 1
              fi
              cat "$fixture"
              exit 0
            fi
            # The release rows are commit-bound: the only release.yml run a
            # row may grade is the one for the version's own sha, requested
            # with --commit. A release.yml request WITHOUT --commit is a row
            # that dropped its binding - it would read the newest run of any
            # shape - so the stub refuses it instead of serving the fixture.
            # Rows 8, 12 and 14 list other workflows without --commit and are
            # answered as usual.
            if [ "$wf" = "release.yml" ] && [ -z "$commit" ]; then
              printf 'stub gh run list: release.yml is commit-bound, refusing a request without --commit: %s\n' "$*" >&2
              exit 1
            fi
            # The run list is served only for the commit the caller asked
            # for, and only when that commit is the sha the version own
            # commit fixture names. A row that dropped the --commit filter
            # would read the newest run of any shape - a run that says
            # nothing about this version - so the stub refuses to answer it.
            if [ -n "$commit" ]; then
              if [ ! -s "$fixdir/version-head.sha" ] || [ "$commit" != "$(cat "$fixdir/version-head.sha")" ]; then
                printf 'stub gh run list: no run for commit %s (the version own sha is %s)\n' "$commit" "$(cat "$fixdir/version-head.sha" 2>/dev/null)" >&2
                exit 1
              fi
            fi
            if [ "$wf" = "release.yml" ]; then
              jq --arg commit "$commit" --arg branch "$branch" --arg event "$event" \
                '[.[] | select(($commit == "" or .headSha == $commit)
                  and ($branch == "" or .headBranch == $branch)
                  and ($event == "" or .event == $event))] | .[:1]' \
                "$fixdir/release-runs.json"
              exit 0
            fi
            if [ -z "$wf" ]; then
              printf 'stub gh run: no --workflow argument in: %s\n' "$*" >&2
              exit 1
            fi
            # The run-list SHAPE, before the fixtures below: `empty` serves a
            # readable list with no run in it, `fail` serves nothing at all
            # (the rate-limit / 4xx shape), and `error-empty`/`error-run` emit
            # their bytes and THEN fail — the half-failed read only a row that
            # checks gh's exit status can catch. All are per workflow, so row
            # 14 can mix shapes across its lanes.
            runs_error=""
            if [ -s "$fixdir/$wf.runs" ]; then
              case "$(cat "$fixdir/$wf.runs")" in
                empty) printf '[]\n'; exit 0 ;;
                fail)
                  printf 'stub gh run list: the run list read fails on purpose (rate limited or 4xx)\n' >&2
                  exit 1
                  ;;
                error-empty)
                  printf '[]\n'
                  printf 'stub gh run list: the read fails on purpose after emitting the empty list\n' >&2
                  exit 1
                  ;;
                error-run) runs_error=1 ;;
              esac
            fi
            printf '[{"databaseId":%s,"headSha":"%s","conclusion":"%s","url":"%s"}]\n' \
              "$(cat "$fixdir/$wf.dbid")" \
              "$(cat "$fixdir/$wf.sha")" \
              "$(cat "$fixdir/$wf.conclusion")" \
              "$(if [ -s "$fixdir/$wf.url" ]; then cat "$fixdir/$wf.url"; else printf 'https://github.com/wurk-owner/wurk/actions/runs/%s' "$(cat "$fixdir/$wf.dbid")"; fi)"
            if [ -n "$runs_error" ]; then
              printf 'stub gh run list: the read fails on purpose after emitting the list\n' >&2
              exit 1
            fi
            ;;
        esac
        ;;
      pr)
        # `gh pr list --state open --app dependabot --json <fields>` — the
        # row's open-PR read. The arguments are matched POSITIONALLY, in the
        # order the brief pins: a request WITHOUT `--state open` is a row
        # that fell back to `gh pr list`'s default state, which says nothing
        # about what is open — so the stub REFUSES it instead of serving the
        # fixture, the way it refuses a release.yml run list without
        # --commit. The `--json` field list is checked the same way: the
        # report reads number, title, createdAt, headRefName, updatedAt,
        # statusCheckRollup and headRefOid, and a request that asks for
        # fewer fields than the report prints is refused too, so a brief
        # that quietly narrowed the read fails closed instead of printing a
        # summary it cannot fill. Anything else under `pr` is unexpected and
        # exits 1, so a regression that calls e.g. `gh pr view` cannot
        # silently pass by reusing the run-row code path.
        if [ "${2:-}" = "list" ] && [ "${3:-}" = "--state" ] && [ "${4:-}" = "open" ] && [ "${5:-}" = "--app" ] && [ "${6:-}" = "dependabot" ]; then
          json=""
          prev=""
          for arg in "$@"; do
            case "$prev" in
              --json) json="$arg" ;;
            esac
            prev="$arg"
          done
          for field in number title createdAt headRefName updatedAt statusCheckRollup headRefOid; do
            case ",$json," in
              *",$field,"*) ;;
              *)
                printf 'stub gh pr: the --json field list (%s) does not request %s\n' "$json" "$field" >&2
                exit 1
                ;;
            esac
          done
          if [ ! -s "$fixdir/dependabot.prs" ]; then
            printf 'stub gh pr: no dependabot.prs fixture for: %s\n' "$*" >&2
            exit 1
          fi
          cat "$fixdir/dependabot.prs"
        else
          printf 'stub gh pr: only `gh pr list --state open --app dependabot` is stubbed (got: %s)\n' "$*" >&2
          exit 1
        fi
        ;;
      repo)
        printf 'wurk-owner/wurk\n'
        ;;
      api)
        for arg in "$@"; do
          case "$arg" in
            *"issues?state=open"*)
              if [ ! -s "$fixdir/issues.json" ]; then
                printf 'stub gh api: no issues fixture for %s\n' "$arg" >&2
                exit 1
              fi
              cat "$fixdir/issues.json"
              exit 0
              ;;
            *"contents/lib/wurk/version.rb"*)
              # The version AT the resolved commit: `gh api -H "Accept:
              # application/vnd.github.raw" .../contents/lib/wurk/version.rb?ref=<sha>`.
              # This file — not the checkout's own copy — is what the release
              # rows grade, so it is served from its own fixture.
              if [ ! -s "$fixdir/version-at-head.rb" ]; then
                printf 'stub gh api: no version-at-head.rb fixture for %s\n' "$arg" >&2
                exit 1
              fi
              cat "$fixdir/version-at-head.rb"
              exit 0
              ;;
            *lib/wurk/version.rb*)
              # The version own commit: the newest main commit that touched
              # lib/wurk/version.rb. This is the sha a release run has to be
              # bound to, so it is also what the run list is filtered by.
              if [ ! -s "$fixdir/version-head.sha" ]; then
                printf 'stub gh api: no version-head.sha fixture for %s\n' "$arg" >&2
                exit 1
              fi
              printf '[{"sha":"%s"}]\n' "$(cat "$fixdir/version-head.sha")"
              exit 0
              ;;
            *"contents/Dockerfile"*|*"contents/mise.toml"*|*"contents/docs/deployment.md"*|*"contents/.github/workflows/"*)
              # Row 15's pin verification: the five bun pin sites at a
              # candidate PR's head, read to verify the mismatch is still
              # outstanding before the PR classifies waiting-on-us. The read
              # is head-bound — `ref=` has to name the sha the pin.head.sha
              # fixture carries, the candidate's own headRefOid — so a row
              # that graded some other tree (main, a base branch) fails
              # closed. A site with no fixture is a failed read, what a 4xx
              # is for real gh. A `pin.<site>.error` marker makes that read
              # print its error body on stdout and exit non-zero FIRST — the
              # shape a real 404 or rate limit produces (bytes on stdout,
              # then failure), which only a row that grades the exit status
              # before the bytes reads as a failed read.
              ref="${arg##*\?ref=}"
              if [ ! -s "$fixdir/pin.head.sha" ] || [ "$ref" != "$(cat "$fixdir/pin.head.sha")" ]; then
                printf 'stub gh api: pin sites are head-bound, refusing ref %s (head is %s)\n' \
                  "$ref" "$(cat "$fixdir/pin.head.sha" 2>/dev/null)" >&2
                exit 1
              fi
              path="${arg%%\?*}"
              path="${path##*/contents/}"
              fixture="$fixdir/pin.${path//\//_}"
              if [ -s "$fixture.error" ]; then
                cat "$fixture.error"
                printf 'stub gh api: the pin read for %s fails on purpose after emitting the error body (a 404 or a rate limit)\n' "$arg" >&2
                exit 1
              fi
              if [ ! -s "$fixture" ]; then
                printf 'stub gh api: no pin fixture for %s (looked for %s)\n' "$arg" "$fixture" >&2
                exit 1
              fi
              cat "$fixture"
              exit 0
              ;;
          esac
        done
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
      release)
        # `gh release view --json author,assets` - the Latest GitHub
        # Release. The release.json fixture is what gh would print; no
        # fixture means the lookup failed (a rate limit, a 4xx, a repository
        # with no release at all), which must grade `verdict unknown`.
        if [ ! -s "$fixdir/release.json" ]; then
          printf 'stub gh release view: no release.json fixture for: %s\n' "$*" >&2
          exit 1
        fi
        cat "$fixdir/release.json"
        ;;
      *)
        printf 'stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :STUB_GH

  # Stub curl for the two rows whose commands leave the GitHub API. It answers
  # both from fixtures and environment, never from the network, and it is
  # faithful to the flags the rows use: `-w FORMAT` is honoured, and — because
  # neither row passes `-f` — the response body is printed for EVERY status, a
  # 404 and a 503 included. Two disjoint arms:
  #
  #   * a rubygems.org versions URL is the release rows' canonical probe. The
  #     status is served ONLY for the version the probe.version fixture names
  #     - the version at the resolved commit; any other version is one
  #     RubyGems does not serve, and the stub answers 404 for it, the real
  #     API's answer for an unknown version. That is what makes the version
  #     binding falsifiable: a row that grades the commit's release run while
  #     probing the checkout's own copy of lib/wurk/version.rb probes a
  #     version RubyGems need not serve, and cannot grade green off it. A
  #     status of 000 simulates a transport failure (no HTTP status at all),
  #     which the row grades `verdict unknown` rather than a colour.
  #   * any other URL is the demo served-version row: the stub serves the
  #     fixture body and status. A real `curl -sS URL` exits 0 and prints the
  #     body whatever the status, so a row that graded the body alone would
  #     read a 404's JSON as a served version; a stub that withheld the body
  #     on a non-200 would let exactly that defect pass.
  #     `WURK_TEST_CURL_EXIT` simulates a transport failure — connection
  #     refused (7), or the probe's `--max-time` deadline exceeded (28) —
  #     which is the only way real curl exits non-zero here.
  #
  # curl's status placeholder is assembled from two shell parts instead of
  # being written out: RuboCop parses a Ruby heredoc's body as Ruby, and
  # `Style/FormatStringToken` flags a `%{...}` template token inside any
  # string literal it finds there — the shell script would have to carry a
  # literal this Ruby can read, which is not what this stub is.
  STUB_CURL = <<~'SHELL'
    #!/usr/bin/env bash
    fixdir="$WURK_TEST_FIXTURES"
    asked=""
    fmt=""
    prev=""
    for arg in "$@"; do
      case "$arg" in
        */versions/*.json)
          tail="${arg##*/versions/}"
          asked="${tail%.json}"
          ;;
      esac
      case "$prev" in
        -w) fmt="$arg" ;;
      esac
      prev="$arg"
    done
    if [ -n "$asked" ]; then
      status="$WURK_TEST_HTTP_STATUS"
      if [ "$status" = "000" ]; then
        printf 'curl: (7) Failed to connect to rubygems.org port 443\n' >&2
        if [ -n "$fmt" ]; then printf '000'; fi
        exit 7
      fi
      if [ ! -s "$fixdir/probe.version" ]; then
        printf 'stub curl: no probe.version fixture (asked for %s)\n' "$asked" >&2
        exit 1
      fi
      if [ "$asked" != "$(cat "$fixdir/probe.version")" ]; then
        if [ -n "$fmt" ]; then printf '404'; fi
        exit 0
      fi
      if [ -n "$fmt" ]; then printf '%s' "$status"; fi
    else
      body="${WURK_TEST_CURL_BODY:-}"
      status="${WURK_TEST_CURL_STATUS:-200}"
      if [ "${WURK_TEST_CURL_EXIT:-0}" != "0" ]; then
        printf 'stub curl: transport failure on purpose\n' >&2
        exit "${WURK_TEST_CURL_EXIT}"
      fi
      printf '%s' "$body"
      if [ -n "$fmt" ]; then
        placeholder='%'
        placeholder="${placeholder}{http_code}"
        printf '%b' "${fmt//"$placeholder"/$status}"
      fi
    fi
    exit 0
  SHELL
  private_constant :STUB_CURL
end
