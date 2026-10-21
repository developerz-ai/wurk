# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'

# Gates the four graded rows of .dz/briefs/health.md (`main` is green, `the
# last release published`, `topology and ecosystem lanes`, `Dependabot is not
# stuck`) the way release_due_brief_test.rb gates release-due.md: these
# commands run unattended on a schedule, and a verdict they cannot actually
# establish must never be printed as a green one. Five properties — the first
# four all pinned by RUNNING the extracted command cells as bash against a
# PATH-stubbed `gh` (a substring match over the brief's text would accept a
# guard that never fires), the fifth pinned byte-for-byte on the brief's text
# plus by running the extracted issues lookup:
#
#   1. FAIL CLOSED. `gh api .../actions/runs/<id>/jobs` is the only thing
#      between a `gh` error and a false green: with the read empty the row falls
#      through to grading on `conclusion`, printing `success <sha>` for a run
#      it knows nothing about.
#   2. The dup signature REQUIRES `detect changed paths` to conclude success.
#      A failed or cancelled detect publishes no outputs, `needs:` skips every
#      dependent, and the job list comes back all-skipped with no dup in it.
#   3. A release run that published NOTHING still concludes success — the jobs
#      that were skipped do not fail the run — so row 9 reads `preflight`
#      success + `release` skipped and names that a no-op. A run still
#      executing (`conclusion=null`) is reported in flight and graded by
#      nobody.
#   4. Row 13 reads the shape `gh` actually emits. `--json statusCheckRollup`
#      is a LIST of CheckRun/StatusContext entries to roll up, never a state on
#      the PR, so a fixture shaped `{"state": "FAILURE"}` agrees with a read the
#      CLI cannot satisfy and grades a 35-day-old failing PR as "" — the row
#      then prints nothing and reports no stuck dependabot PR, ever. Every
#      fixture below is CLI-shaped for that reason: it is the only thing that
#      lets the stuck assertions fail.
#   5. The filing rule's ask dedupe is executable and mirrors release-due.md:
#      the paragraph carries the byte-identical issues lookup, the lookup
#      really drops PR entries, and ask titles are stable per signal — exact
#      equality on a title that embeds the run's headSha or version can never
#      hit, so the ask would be re-filed on every checkup.
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
  SHA_TOPOLOGY   = 'c' * 40
  SHA_ECOSYSTEM  = 'e' * 40
  SHA_PUBLISHED  = 'b' * 40
  SHA_NOOP       = 'f' * 40
  SHA_REFUSED    = '9' * 40
  SHA_INFLIGHT   = '1' * 40

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

  # Pins the recovery paragraph in .dz/briefs/health.md — the prose a
  # red-main or release-failure ask points the responder at. RELEASE.md owns
  # the recovery runbook; this paragraph is a pointer, not a re-write. Two
  # properties have to hold so it does not silently forbid something the
  # runbook prescribes:
  #
  #   1. The paragraph NAMES the runbook steps it points at: both
  #      headings — *If a release fails* and *Recovering a gem-less
  #      release* — and the two commands the gem-less subsection actually
  #      prescribes (`gh release delete ... --cleanup-tag`, then
  #      `git fetch --prune-tags`). Pin them with a substring assertion
  #      over the joined paragraph — markdown italic can wrap across a
  #      line break, so the assertion reads the paragraph as one string.
  #   2. The paragraph does NOT forbid the sanctioned steps the rest of
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

  def test_release_run_that_published_grades_on_conclusion
    out, err, status = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'success', demo: 'success'),
                                conclusion: 'success', sha: SHA_PUBLISHED)

    assert_predicate status, :success?,
                     "row 9's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["success #{SHA_PUBLISHED}"], out.lines.map(&:chomp),
                 'a run that really pushed the gem and cut the tag is an ordinary ' \
                 'publish: grade on conclusion and print exactly `success <sha>`'

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

    assert_equal ["in flight #{SHA_INFLIGHT}"], out.lines.map(&:chomp),
                 'a run with a null conclusion has not finished; report it in flight ' \
                 "and grade nothing (stdout=#{out.inspect})"

    refute_includes out, 'Unhealthy',
                    'still running is not a red release'
    refute_includes out, "success #{SHA_INFLIGHT}",
                    'a run that has not concluded cannot be a green publish'
  end

  def test_failed_preflight_is_not_read_as_a_no_op
    # release.yml:55-60 refuses any ref but main with a FAILING step, not a
    # job-level `if:` — a skipped preflight would leave a green run that
    # published nothing and said nothing. `needs:` then skips release and demo,
    # so the job list is the same all-skipped shape a proceed=false run
    # produces; only preflight's own conclusion tells the two apart.
    out, err, status = run_row9(jobs: release_jobs_json(preflight: 'failure', release: 'skipped', demo: 'skipped'),
                                conclusion: 'failure', sha: SHA_REFUSED)

    assert_predicate status, :success?,
                     "row 9's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_equal ["failure #{SHA_REFUSED}"], out.lines.map(&:chomp),
                 'a refused release published nothing and was red; it grades on its ' \
                 "own conclusion, not as a no-op (stdout=#{out.inspect})"

    refute_includes out, 'no-op',
                    'proceed=false requires preflight itself to have succeeded'
  end

  # Row 13 grades dependabot PRs against per-ecosystem budgets. The brief
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
      'isDraft' => false,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row13(prs: [pr])

    assert_predicate status, :success?,
                     "row 13's command must run cleanly (status=#{status.inspect})"

    refute_includes out, '#7001',
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
      'isDraft' => false,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row13(prs: [pr])

    assert_predicate status, :success?,
                     "row 13's command must run cleanly (status=#{status.inspect})"

    refute_includes out, '#7102',
                    'a red docker PR aged 5d is exactly the expected-red shape of ' \
                    "dependabot.yml:63-72; it must NOT print the PR number (stdout=#{out.inspect})"
    refute_includes out, 'Unhealthy',
                    'an expected-red PR is the headline of dependabot.yml:63-72, not a ' \
                    "regression the row should file (stdout=#{out.inspect})"
  end

  def test_pr_past_ecosystem_budget_and_red_is_reported_stuck
    # bundler: 35-day-old PR whose check run concluded FAILURE. Budget is 28d
    # (weekly interval + 14d cooldown + 7d margin, dependabot.yml:27-30). The
    # PR has run past its entire grace window — it IS stuck. The row must
    # print one `Unhealthy: Dependabot is stuck on #<n>` line naming the
    # number, so the ask can link the PR (cf. health.md:105-114).
    now = Time.now.utc
    pr = {
      'number' => 7203,
      'title' => 'Bump rubocop from 2.0.0 to 2.1.0 in /',
      'createdAt' => (now - (35 * 86_400)).iso8601,
      'isDraft' => false,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row13(prs: [pr])

    assert_predicate status, :success?,
                     "row 13's command must run cleanly (status=#{status.inspect})"

    lines = out.lines.map(&:chomp)

    assert_equal 1, lines.size,
                 'one stuck PR prints one line — the row names per-PR, not a ' \
                 "summary (stdout=#{out.inspect})"

    assert_match(/\AUnhealthy: Dependabot is stuck on #7203\b/, lines.first,
                 'the stuck line must name the signal and the PR number so the ask ' \
                 "can link it (got #{lines.first.inspect})")

    assert_match(/\(age 35d > 28d budget for bundler\)\z/, lines.first,
                 'the line must carry the age and the bundler budget, so a reader can ' \
                 "see WHY this is stuck without re-running the command (got #{lines.first.inspect})")
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
      'isDraft' => false,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row13(prs: [stuck])

    assert_predicate status, :success?,
                     "row 13's command must run cleanly (status=#{status.inspect})"

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
      'isDraft' => false,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row13(prs: [pr])

    assert_predicate status, :success?,
                     "row 13's command must run cleanly (status=#{status.inspect})"

    assert_equal [], out.lines.map(&:chomp),
                 'a red bun PR aged 5d is under its 14d budget (dependabot.yml:41-49); ' \
                 "the row must print nothing at all (stdout=#{out.inspect})"
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
      'isDraft' => false,
      'statusCheckRollup' => [check_run('FAILURE')]
    }
    out, _err, status = run_row13(prs: [pr])

    assert_predicate status, :success?,
                     "row 13's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'budget for github-actions',
                    'the grouped `Bump the github-actions group with N updates` title ' \
                    "(dependabot.yml:60-62) must map to github-actions' 37d budget, " \
                    "not the 28d bundler default (stdout=#{out.inspect})"

    refute_includes out, 'budget for bundler',
                    'a grouped github-actions PR is not a bundler PR; grading it ' \
                    "bundler would apply the wrong budget (stdout=#{out.inspect})"
  end

  def test_past_budget_but_green_pr_is_not_stuck
    # health.md:103's first half: a PR past its budget whose checks all
    # concluded SUCCESS is not stuck — an old green is just an old
    # human-pending merge, not a regression dependabot can fix on its own.
    # This is the same 35d/28d bundler shape as the stuck test, differing
    # only in what the rollup grades.
    now = Time.now.utc
    pr = {
      'number' => 7307,
      'title' => 'Bump rubocop from 2.0.0 to 2.1.0 in /',
      'createdAt' => (now - (35 * 86_400)).iso8601,
      'isDraft' => false,
      'statusCheckRollup' => [check_run('SUCCESS')]
    }
    out, _err, status = run_row13(prs: [pr])

    assert_predicate status, :success?,
                     "row 13's command must run cleanly (status=#{status.inspect})"

    assert_equal [], out.lines.map(&:chomp),
                 'a past-budget PR whose checks all concluded SUCCESS is an old green ' \
                 'pending merge, not stuck (health.md:103); the row must print nothing ' \
                 "(stdout=#{out.inspect})"
  end

  def test_past_budget_but_pending_pr_is_not_stuck
    # health.md:103's second half: a rollup that is still PENDING is in flight,
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
      'isDraft' => false,
      'statusCheckRollup' => [check_run('SUCCESS'), running_check_run]
    }
    out, _err, status = run_row13(prs: [pr])

    assert_predicate status, :success?,
                     "row 13's command must run cleanly (status=#{status.inspect})"

    assert_equal [], out.lines.map(&:chomp),
                 'a past-budget PR with a check still running is in flight, not ' \
                 "stuck (health.md:103); the row must print nothing (stdout=#{out.inspect})"
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
      'isDraft' => false,
      'statusCheckRollup' => [check_run('SUCCESS'), running_check_run, status_context('FAILURE')]
    }
    out, _err, status = run_row13(prs: [pr])

    assert_predicate status, :success?,
                     "row 13's command must run cleanly (status=#{status.inspect})"

    assert_equal 1, out.lines.size,
                 "one stuck PR prints one line; got #{out.lines.inspect}"

    stuck = out.lines.map(&:chomp).first

    assert_match(/\AUnhealthy: Dependabot is stuck on #7309\b/, stuck,
                 'one failed entry makes the whole PR red, however green or ' \
                 "still-running the rest of the rollup is; got #{out.inspect}")

    assert_match(/\(age 40d > 37d budget for github-actions\)\z/, stuck,
                 "the ecosystem still comes from the title, not the rollup; got #{stuck.inspect}")
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
      'isDraft' => false,
      'statusCheckRollup' => [check_run('SUCCESS'), check_run('TIMED_OUT')]
    }
    out, _err, status = run_row13(prs: [pr])

    assert_predicate status, :success?,
                     "row 13's command must run cleanly (status=#{status.inspect})"

    assert_match(/\AUnhealthy: Dependabot is stuck on #7311\b/, out.lines.map(&:chomp).first.to_s,
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
      'isDraft' => false,
      'statusCheckRollup' => [check_run('SUCCESS'), status_context('ERROR')]
    }
    out, _err, status = run_row13(prs: [pr])

    assert_predicate status, :success?,
                     "row 13's command must run cleanly (status=#{status.inspect})"

    assert_match(/\(age 35d > 28d budget for bundler\)\z/, out.lines.map(&:chomp).first.to_s,
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
        'isDraft' => false,
        'statusCheckRollup' => rollup
      }
      out, _err, status = run_row13(prs: [pr])

      assert_predicate status, :success?,
                       "row 13's command must run cleanly (status=#{status.inspect})"

      assert_equal [], out.lines.map(&:chomp),
                   "rollup #{rollup.inspect} has nothing red in it, so the row must " \
                   "print nothing at 35d (stdout=#{out.inspect})"
    end
  end

  def test_unreadable_dependabot_pr_list_fails_closed
    # If the stub cannot serve `gh pr list --app dependabot --json ...`, the
    # brief command must not fall through to printing a green verdict. The
    # stub's `pr` arm errors out without a fixture, so `gh` writes nothing to
    # stdout; the brief's `jq -e 'type == "array"'` check then sees an empty
    # string and the row prints `verdict unknown dependabot` so the next
    # checkup re-runs it. Same shape as rows 8 and 9's fail-closed rule.
    out, _err, _status = run_command(
      command_cell('Dependabot is not stuck', gh_command: 'gh pr list'),
      jobs_fail: false
    ) { |_fixtures| } # no dependabot.prs fixture is written

    refute_includes out, 'Dependabot is stuck on ',
                    'an unreadable pr list cannot have produced a stuck verdict ' \
                    "(stdout=#{out.inspect})"
    assert_includes out, 'verdict unknown',
                    'an unreadable pr list must surface as `verdict unknown`, the same ' \
                    "fail-closed shape rows 8 and 9 use (stdout=#{out.inspect})"
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

    ['`main is red`', '`main is green only via a dup\'d push`',
     '`release did not publish`'].each do |title|
      assert_includes para, title,
                      'the dedupe match is exact equality on the title, so every title the ' \
                      'brief gives must be the signal\'s stable name, identical on every ' \
                      "occurrence; the filing paragraph is missing #{title}"
    end

    ['`main is red at <sha>`',
     '`main is green only via a dup\'d push at <sha>`',
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

  private

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

  # One `CheckRun` entry exactly as `gh pr list --json statusCheckRollup` emits
  # it. The rollup is the GraphQL union `StatusCheckRollupContext`, so it
  # arrives as a LIST of these and of `status_context` entries — never as an
  # object carrying a `.state` on the PR itself.
  def check_run(conclusion, status: 'COMPLETED', name: 'test + coverage (latest ruby/rails)')
    entry = { '__typename' => 'CheckRun', 'name' => name, 'status' => status,
              'conclusion' => conclusion, 'workflowName' => 'CI',
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

  def write_fixture(dir, name, body)
    File.write(File.join(dir, name), body)
  end

  # The `Command` cell of the row whose Signal cell contains `signal`. Cells
  # are `|`-separated and the commands are full of shell pipes, so the cell is
  # cut at its backticks instead: the command opens at the last backtick before
  # its own `gh_command` token and closes at the next one after it. `\|` is
  # markdown's escape for a literal pipe inside a cell. `gh_command` defaults
  # to `gh run list` for the run-list rows; row 13 grades dependabot via
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
  # cannot be satisfied by a mention somewhere else in the file.
  def filing_paragraph
    para = @text.split(/\n\s*\n/).find { |candidate| candidate.include?('file one ask') }
    raise 'health.md has no filing paragraph saying when to file one ask' if para.nil?

    para
  end

  # The backticked issues lookup the filing paragraph requires before any ask
  # is filed — the dedupe guard's executable core, extracted so the tests can
  # RUN it rather than trust its spelling.
  def lookup_command
    command = @text[/`([^`]*issues\?state=open[^`]*)`/, 1]
    raise 'health.md carries no backticked issues?state=open lookup' if command.nil?

    command
  end

  def run_row8(jobs:, conclusion:, sha:, jobs_fail: false)
    run_command(command_cell('`main` is green'), jobs_fail: jobs_fail) do |fixtures|
      write_fixture(fixtures, 'test.yml.dbid', '1')
      write_fixture(fixtures, 'test.yml.sha', sha)
      write_fixture(fixtures, 'test.yml.conclusion', conclusion)
      write_fixture(fixtures, 'dbid-1.jobs', jobs)
    end
  end

  def run_row9(jobs:, conclusion:, sha:, jobs_fail: false)
    run_command(command_cell('the last release published'), jobs_fail: jobs_fail) do |fixtures|
      write_fixture(fixtures, 'release.yml.dbid', '201')
      write_fixture(fixtures, 'release.yml.sha', sha)
      write_fixture(fixtures, 'release.yml.conclusion', conclusion)
      write_fixture(fixtures, 'dbid-201.jobs', jobs)
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

  # Row 13 grades dependabot PRs against per-ecosystem budgets derived from
  # dependabot.yml (28d bundler, 14d bun, 37d github-actions, 37d docker). The
  # stub `gh` answers `gh pr list --app dependabot --json ...` from
  # $WURK_TEST_FIXTURES/dependabot.prs, so the command runs against fixed
  # fixtures instead of the API — fixtures shaped like the list `gh` really
  # emits, rollup included. `jobs_fail` is ignored — row 13 does not call
  # `gh api .../jobs`, so there is no separate failure-shape to pin here.
  def run_row13(prs:, jobs_fail: false)
    run_command(command_cell('Dependabot is not stuck', gh_command: 'gh pr list'), jobs_fail: jobs_fail) do |fixtures|
      write_fixture(fixtures, 'dependabot.prs', JSON.generate(prs))
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
  # The issues lookup is answered BEFORE the failure gate below: it is not the
  # jobs call, and jobs-fail mode exists to break exactly one call, not the
  # dedupe lookup beside it.
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
      pr)
        # Match `gh pr list --app dependabot --json ...` only — anything else
        # under `pr` is unexpected, exits 1, so a regression that calls e.g.
        # `gh pr view` cannot silently pass by reusing the run-row code path.
        # The dependabot.prs fixture is whatever JSON the test wrote; the
        # `--json` field list is not inspected, because the brief itself does
        # not pin it (a regression that adds/removes a field still parses).
        if [ "${2:-}" = "list" ] && [ "${3:-}" = "--app" ] && [ "${4:-}" = "dependabot" ]; then
          if [ ! -s "$fixdir/dependabot.prs" ]; then
            printf 'stub gh pr: no dependabot.prs fixture for: %s\n' "$*" >&2
            exit 1
          fi
          cat "$fixdir/dependabot.prs"
        else
          printf 'stub gh pr: only `gh pr list --app dependabot` is stubbed (got: %s)\n' "$*" >&2
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
      *)
        printf 'stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :STUB_GH
end
