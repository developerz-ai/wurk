# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'

# Gates the three job-list-aware rows of .dz/briefs/health.md (`main` is
# green, `the last release published`, `topology and ecosystem lanes`) the way
# release_due_brief_test.rb gates release-due.md: these commands run unattended
# on a schedule, and a verdict they cannot actually establish must never be
# printed as a green one. Three properties, all pinned by RUNNING the extracted
# command cells as bash against a PATH-stubbed `gh` — a substring match over the
# brief's text would accept a guard that never fires:
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
#
# A fourth property, added with the run URLs: every job-list row must request
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
  RELEASE_WORKFLOW = File.join(ROOT, '.github', 'workflows', 'release.yml')

  SHA_DUP        = 'd' * 40
  SHA_GREEN      = 'a' * 40
  SHA_TOPOLOGY   = 'c' * 40
  SHA_ECOSYSTEM  = 'e' * 40
  SHA_PUBLISHED  = 'b' * 40
  SHA_NOOP       = 'f' * 40
  SHA_REFUSED    = '9' * 40
  SHA_INFLIGHT   = '1' * 40

  URL_TEST        = 'https://github.com/wurk-owner/wurk/actions/runs/1'
  URL_RELEASE     = 'https://github.com/wurk-owner/wurk/actions/runs/201'
  URL_TOPOLOGY    = 'https://github.com/wurk-owner/wurk/actions/runs/101'
  URL_ECOSYSTEM   = 'https://github.com/wurk-owner/wurk/actions/runs/102'

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

    assert_equal ["success #{SHA_GREEN} #{URL_TEST}"], out.lines.map(&:chomp),
                 'gated jobs that really ran make this an ordinary main run: the ' \
                 'row grades on conclusion and prints `success <sha> <url>`'

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

    assert_equal ["failure #{SHA_DUP} #{URL_TEST}"], out.lines.map(&:chomp),
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

    assert_includes lines, "ecosystem.yml success #{SHA_ECOSYSTEM} #{URL_ECOSYSTEM}",
                    'the healthy lane still grades on its own conclusion and reports ' \
                    "its own sha and run url; got #{lines.inspect}"
  end

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

    assert_equal ["failure #{SHA_REFUSED} #{URL_RELEASE}"], out.lines.map(&:chomp),
                 'a refused release published nothing and was red; it grades on its ' \
                 "own conclusion, not as a no-op (stdout=#{out.inspect})"

    refute_includes out, 'no-op',
                    'proceed=false requires preflight itself to have succeeded'
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
    # The URL has to survive into every branch, not just the green one: a dup,
    # an unknown and a no-op are exactly the lines that become an ask.
    out, = run_row8(jobs: jobs_json(detect: 'success', gated: 'skipped'),
                    conclusion: 'success', sha: SHA_DUP)

    assert_includes out, URL_TEST,
                    "a dup verdict must carry the run url too; got #{out.inspect}"

    out, = run_row8(jobs: jobs_json(detect: 'success', gated: 'skipped'),
                    conclusion: 'success', sha: SHA_DUP, jobs_fail: true)

    assert_includes out, URL_TEST,
                    'an ungraded (`verdict unknown`) line must still carry the run ' \
                    "url; got #{out.inspect}"

    out, = run_row9(jobs: release_jobs_json(preflight: 'success', release: 'skipped', demo: 'skipped'),
                    conclusion: 'success', sha: SHA_NOOP)

    assert_includes out, URL_RELEASE,
                    "a no-op line must carry the run url; got #{out.inspect}"

    out, = run_row12

    assert_includes out, URL_TOPOLOGY,
                    "the dup'd lane's Unhealthy line must carry its run url; got #{out.inspect}"
    assert_includes out, URL_ECOSYSTEM,
                    "the healthy lane's line must carry its own run url; got #{out.inspect}"
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
    # list is still `verdict unknown`.
    out, = run_row8(jobs: jobs_json(detect: 'failure', gated: 'skipped'),
                    conclusion: 'failure', sha: SHA_DUP)

    refute_includes out, 'Unhealthy',
                    'documenting the dup signature must not turn a failed detect into ' \
                    "a dup; got #{out.inspect}"

    out, = run_row8(jobs: jobs_json(detect: 'success', gated: 'skipped'),
                    conclusion: 'success', sha: SHA_DUP, jobs_fail: true)

    assert_includes out, 'verdict unknown',
                    "the fail-closed unknown grade must survive; got #{out.inspect}"
  end

  private

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
      write_fixture(fixtures, 'test.yml.url', URL_TEST)
      write_fixture(fixtures, 'dbid-1.jobs', jobs)
    end
  end

  def run_row9(jobs:, conclusion:, sha:, jobs_fail: false)
    run_command(command_cell('the last release published'), jobs_fail: jobs_fail) do |fixtures|
      write_fixture(fixtures, 'release.yml.dbid', '201')
      write_fixture(fixtures, 'release.yml.sha', sha)
      write_fixture(fixtures, 'release.yml.conclusion', conclusion)
      write_fixture(fixtures, 'release.yml.url', URL_RELEASE)
      write_fixture(fixtures, 'dbid-201.jobs', jobs)
    end
  end

  def run_row12(jobs_fail: false)
    run_command(command_cell('topology and ecosystem lanes'), jobs_fail: jobs_fail) do |fixtures|
      write_fixture(fixtures, 'topology.yml.dbid', '101')
      write_fixture(fixtures, 'topology.yml.sha', SHA_TOPOLOGY)
      write_fixture(fixtures, 'topology.yml.conclusion', 'success')
      write_fixture(fixtures, 'topology.yml.url', URL_TOPOLOGY)
      write_fixture(fixtures, 'dbid-101.jobs', jobs_json(detect: 'success', gated: 'skipped'))

      write_fixture(fixtures, 'ecosystem.yml.dbid', '102')
      write_fixture(fixtures, 'ecosystem.yml.sha', SHA_ECOSYSTEM)
      write_fixture(fixtures, 'ecosystem.yml.conclusion', 'success')
      write_fixture(fixtures, 'ecosystem.yml.url', URL_ECOSYSTEM)
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
  # The run list also serves `url`, from a per-workflow `<wf>.url` fixture and
  # falling back to a run-URL derived from the databaseId — the brief asks for
  # `url` by name, so a stub that dropped it would hand the row a literal
  # `null` and let a broken row pass.
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
        printf '[{"databaseId":%s,"headSha":"%s","conclusion":"%s","url":"%s"}]\n' \
          "$(cat "$fixdir/$wf.dbid")" \
          "$(cat "$fixdir/$wf.sha")" \
          "$(cat "$fixdir/$wf.conclusion")" \
          "$(if [ -s "$fixdir/$wf.url" ]; then cat "$fixdir/$wf.url"; else printf 'https://github.com/wurk-owner/wurk/actions/runs/%s' "$(cat "$fixdir/$wf.dbid")"; fi)"
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
