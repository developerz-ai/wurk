# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'

# Gates the alignment between .github/workflows/release.yml's `release` job
# publish tail (the `- name:` steps that follow `build & verify gem`) and
# the step table in RELEASE.md, and the alignment between the brief's
# `RELEASE.md:<a>-<b>` anchor and the gem-less-marker block. RELEASE.md is
# the landing page a maintainer reaches for about a step before any other,
# and the table has drifted before (one row merged three `- name:` values
# into a single sentence); without this gate, the step table and the brief
# anchor can silently fall out of sync with the workflow. Reads files;
# touches no Redis or shared state. The row-10 verdict tests additionally RUN
# the brief's extracted availability-probe command against a stubbed curl and
# gh (no network), one test per verdict.
class ReleaseDocClaimsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  RELEASE_MD = File.join(ROOT, 'RELEASE.md')
  RELEASE_YML = File.join(ROOT, '.github', 'workflows', 'release.yml')
  BRIEF = File.join(ROOT, '.dz', 'briefs', 'release-due.md')
  HEALTH_BRIEF = File.join(ROOT, '.dz', 'briefs', 'health.md')

  SHA_RELEASE_RUN = 'b' * 40
  # The commit that carries Wurk::VERSION. release.yml publishes the version
  # that commit carries, so the run row 10 reads is the one BOUND to it - the
  # same sha by construction.
  SHA_VERSION_HEAD = SHA_RELEASE_RUN
  URL_RELEASE_RUN = 'https://github.com/wurk-owner/wurk/actions/runs/201'

  # The publish tail is derived from release.yml by structural position —
  # inside the `release:` job, every `- name:` step AFTER `build & verify
  # gem`. Counting them is not hardcoded: if a future step is added at the
  # tail end, this test picks it up automatically.
  def test_release_table_steps_match_release_yml_publish_tail_in_order
    workflow_tail = publish_tail_step_names
    md_steps = table_step_names

    refute_empty workflow_tail,
                 "release.yml's `release` job has no `- name:` steps after `build & verify gem`; " \
                 'the publish tail should have at least one step'

    matches = md_steps.each_cons(workflow_tail.length).any? do |window|
      window == workflow_tail
    end

    assert matches,
           'RELEASE.md\'s step table must list release.yml\'s publish-tail `- name:` values ' \
           'as consecutive rows in workflow order; ' \
           "workflow=#{workflow_tail.inspect}, table=#{md_steps.inspect}"
  end

  # Catches drift between the brief's `RELEASE.md:<a>-<b>` cite and the
  # gem-less-marker block the cite is supposed to point at. Without this
  # assertion, an edit to RELEASE.md that retitles a section (or inserts
  # a paragraph above the bash fence) can move the cited range away from
  # the bash fence and the `gem-less release` sentence it grounds.
  def test_brief_anchor_landing_covers_gem_less_marker_block
    cite = brief_release_md_anchor

    refute_nil cite,
               '.dz/briefs/release-due.md must cite a single `RELEASE.md:<a>-<b>` range'

    lines = File.readlines(RELEASE_MD)
    if cite[:last] > lines.length
      raise "RELEASE.md cite #{cite[:first]}-#{cite[:last]} past EOF (file has #{lines.length} lines)"
    end

    cited = lines[(cite[:first] - 1)..(cite[:last] - 1)].join

    assert_includes cited, '```bash',
                    "RELEASE.md:#{cite[:first]}-#{cite[:last]} must include the bash fence " \
                    '(the brief cites this range to point at the gem-less-marker block)'
    assert_includes cited, 'gem-less release',
                    "RELEASE.md:#{cite[:first]}-#{cite[:last]} must include the " \
                    "'gem-less release' marker sentence"
  end

  # Each `- name:` step inside the `release` job whose entry comes AFTER
  # the `build & verify gem` step, in workflow order. Bounded by the next
  # 2-space-indent job (the `demo` job that follows) — the comment block
  # above `demo:` sits at the same indent and is excluded.
  def publish_tail_step_names
    workflow = File.readlines(RELEASE_YML)
    release_idx = workflow.index { |l| l.match?(/\A  release:\s*(?:#.*)?\z/) }
    raise 'release.yml: no `release:` job found' unless release_idx

    job_end_offset = workflow[(release_idx + 1)..].index do |l|
      l.match?(/\A  [a-zA-Z_]/) && !l.lstrip.start_with?('#')
    end
    job_end = job_end_offset ? (release_idx + 1 + job_end_offset) : workflow.length

    block = workflow[(release_idx + 1)...job_end]
    build_offset = block.index { |l| l.include?('build & verify gem') }
    raise 'release.yml: no `build & verify gem` step inside the `release` job' unless build_offset

    block[(build_offset + 1)..]
      .grep(/\A\s+- name:\s+/)
      .map { |l| l.sub(/\A\s+- name:\s+/, '').chomp }
  end

  # The second cell of every row in RELEASE.md's `# | Job / step | Detail`
  # table, with surrounding `**…**` and any wrapping backticks stripped.
  # The bold-cell style is inconsistent across rows (some use `**name**`,
  # others `**`name`**), so the comparison normalises to the bare name.
  # The table ends at the first blank line after the header separator.
  def table_step_names
    text = File.readlines(RELEASE_MD)
    header_idx = text.index { |l| l.include?('| # | Job / step | Detail |') }
    raise 'RELEASE.md: no step table header found' unless header_idx

    text.drop(header_idx + 2).take_while { |l| !l.strip.empty? }.map do |line|
      cells = line.split('|', -1).map(&:strip).reject(&:empty?)
      next nil if cells.length < 2

      cells[1].sub(/\A\*\*(.*?)\*\*\z/, '\1').delete('`').strip
    end.compact
  end

  # Pins the availability probe so RELEASE.md and the health checkup brief
  # cannot drift apart again: both must name the canonical RubyGems API v2
  # per-version endpoint that release.yml's preflight and release-smoke.yml
  # already run, RELEASE.md must present it as THE availability check (with
  # interpretable results), and health.md's `RubyGems serves` row must use it
  # as its predicate instead of `gem list wurk --remote`.
  def test_availability_probe_is_canonical_and_aligned_across_docs
    endpoint = 'rubygems.org/api/v2/rubygems/wurk/versions/'

    release_text = File.read(RELEASE_MD)
    health_text = File.read(HEALTH_BRIEF)

    assert_includes release_text, endpoint,
                    'RELEASE.md must name the canonical RubyGems API v2 per-version endpoint'
    assert_includes health_text, endpoint,
                    '.dz/briefs/health.md must name the same canonical endpoint'

    section = verifying_section(release_text)

    refute_nil section,
               "RELEASE.md must keep its 'Verifying a release actually shipped' section"
    assert_includes section, 'ONE availability probe',
                    'the section must present the v2 probe as THE availability check, ' \
                    'not one of several competing predicates'
    assert_includes section, 'HTTP 200',
                    'the section must give the probe an interpretable HTTP 200 result'
    assert_includes section, 'HTTP 404',
                    'the section must give the probe an interpretable HTTP 404 result'
    assert_match(/probe failed|PROBE failed/, section,
                 'the section must state a failed probe is not evidence the version is absent')

    row = health_rubygems_row

    refute_includes row, 'gem list wurk --remote',
                    "health.md's 'RubyGems serves' row must not carry " \
                    '`gem list wurk --remote` as its predicate'
  end

  # A lib/wurk/version.rb body carrying `version` — the shape the stubbed
  # contents API serves for the version-carrying commit.
  def version_rb_content(version)
    <<~RUBY
      # frozen_string_literal: true

      module Wurk
        VERSION = '#{version}'
      end
    RUBY
  end

  # The row's `<version>` is read from lib/wurk/version.rb AT the
  # version-carrying commit, never from the checkout's own copy of the file:
  # a version bump that lands on main after the checkout must not let the
  # row certify the newer release with the older gem's HTTP 200. The stub
  # serves 9.9.9 at the commit and the curl stub answers 200 only for the
  # version the URL asks for, so a row that slipped back to grepping the
  # checkout's copy probes this checkout's own VERSION, gets a 404 (the real
  # API's answer for an unserved version), and cannot print success.
  def test_row10_probes_the_version_at_the_commit_not_the_checkouts_copy
    out, err, status = run_row10(http_status: 200,
                                 version_at_head: version_rb_content('9.9.9'))

    assert_predicate status, :success?,
                     "row 10's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'success: RubyGems serves 9.9.9',
                    'the probe must ask for the version AT the version-carrying commit ' \
                    '(9.9.9), not this checkout\'s own VERSION, which RubyGems need not ' \
                    "serve; got stdout=#{out.inspect}"

    refute_includes out, 'verdict unknown',
                    'the commit carries a readable version, so the probe must find it'
  end

  # An unreadable version at the commit fails closed: without a version of
  # record there is nothing to probe and nothing to grade.
  def test_row10_version_unreadable_at_the_commit_fails_closed
    out, err, _status = run_row10(http_status: 200, version_at_head: nil)

    assert_includes out, 'verdict unknown',
                    'the contents read failed, so there is no version of record to ' \
                    "probe; got stdout=#{out.inspect}, stderr=#{err.inspect}"

    refute_includes out, 'success',
                    'no version, no probe, no green; ' \
                    "got stdout=#{out.inspect}"

    refute_includes out, 'Unhealthy',
                    'an unreadable version is not evidence the release failed; ' \
                    "got stdout=#{out.inspect}"
  end

  # ---- Row 10's verdicts ---------------------------------------------------
  #
  # The version test above proves the row NAMES the version at the
  # version-carrying commit; these pin what it does with the probe's answer,
  # by RUNNING the extracted command against a stubbed curl and gh. The run
  # the 404 branch reads is the
  # release.yml run BOUND to the version's own commit (the newest main commit
  # that touched lib/wurk/version.rb), not the newest run of any shape: a run
  # for another sha says nothing about this version, so the stub serves the
  # run list only for the version's own sha and a row that dropped the
  # --commit filter cannot pass by reusing the fixture.
  # The row originally graded with
  # `curl -f ... || echo "verdict unknown"`: `-f` makes every HTTP error exit
  # non-zero, so HTTP 404 — RELEASE.md's "the release did not ship" — and a
  # dead network collapsed into the same `verdict unknown`, and a genuinely
  # missing release could never grade Unhealthy. The row now captures the HTTP
  # status (`curl -w '%{http_code}'`, no `-f`) and grades four verdicts, each
  # pinned by a test here: 200 -> success; 404 beside a concluded release run
  # -> Unhealthy; 404 beside an in-flight run -> in flight; 404 beside an
  # unreadable run list, a 5xx, or a transport failure -> verdict unknown.

  # Runs against the checkout's REAL lib/wurk/version.rb served at the
  # commit: the healthy verdict naming the constant's value is what keeps the
  # extraction's grep class honest (a `"…"`-only pattern against the
  # single-quoted VERSION once shipped and left $v empty — it now fails
  # closed as `verdict unknown`, which the assertions below refuse).
  def test_row10_http_200_grades_success
    out, err, status = run_row10(http_status: 200)

    assert_predicate status, :success?,
                     "row 10's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'success',
                    'HTTP 200 means RubyGems serves the version, the probe\'s healthy ' \
                    "verdict; got stdout=#{out.inspect}"

    assert_includes out, rubygems_version,
                    'the healthy verdict must name the version it found; ' \
                    "got stdout=#{out.inspect}"

    refute_includes out, 'Unhealthy', 'HTTP 200 is not Unhealthy'
    refute_includes out, 'verdict unknown', 'a readable 200 is a verdict, not an unknown'
  end

  def test_row10_http_404_with_a_concluded_release_run_is_unhealthy
    run_json = JSON.generate([{ 'conclusion' => 'failure', 'headSha' => SHA_RELEASE_RUN,
                                'url' => URL_RELEASE_RUN }])
    out, err, status = run_row10(http_status: 404, release_run: run_json)

    assert_predicate status, :success?,
                     "row 10's command must run cleanly (status=#{status.inspect}, " \
                     "stdout=#{out.inspect}, stderr=#{err.inspect})"

    assert_includes out, 'Unhealthy',
                    'a 404 beside a CONCLUDED release run is a genuinely missing release ' \
                    'and must grade Unhealthy: under `curl -f` the same probe graded ' \
                    '`verdict unknown`, so a missing release could never go red; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, rubygems_version,
                    'the Unhealthy verdict must name the version RubyGems does not serve; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, URL_RELEASE_RUN,
                    'the Unhealthy verdict must carry the release run url, so the ask can ' \
                    "link the run it graded against; got stdout=#{out.inspect}"

    refute_includes out, 'verdict unknown',
                    'a readable 404 and a readable run list are a verdict, not an unknown'
  end

  def test_row10_http_404_with_a_release_run_in_flight_grades_in_flight
    run_json = JSON.generate([{ 'conclusion' => nil, 'headSha' => SHA_RELEASE_RUN,
                                'url' => URL_RELEASE_RUN }])
    out, _err, status = run_row10(http_status: 404, release_run: run_json)

    assert_predicate status, :success?,
                     "row 10's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'in flight',
                    'a 404 while release.yml is still running is propagation, not a missing ' \
                    'release — the second healthy state the row\'s Healthy column names; ' \
                    "got stdout=#{out.inspect}"

    assert_includes out, URL_RELEASE_RUN,
                    'the in-flight line must carry the release run url; ' \
                    "got stdout=#{out.inspect}"

    refute_includes out, 'Unhealthy',
                    'a run that has not concluded may still publish and propagate the gem'
    refute_includes out, 'verdict unknown',
                    'a readable 404 and a readable run list are a verdict, not an unknown'
  end

  def test_row10_newer_rejected_dispatch_does_not_alarm_for_inflight_or_absent_primary
    primary = { headBranch: 'main', event: 'push', headSha: SHA_VERSION_HEAD,
                conclusion: nil, url: URL_RELEASE_RUN }
    rejected_url = "#{URL_RELEASE_RUN}0"
    rejected = primary.merge(headBranch: 'topic', event: 'workflow_dispatch',
                             conclusion: 'failure', url: rejected_url)
    [[rejected, primary], [rejected]].each do |runs|
      out, err, status = run_row10(http_status: 404, release_run: JSON.generate(runs))

      assert_predicate status, :success?, err
      refute_includes out, 'Unhealthy'
      refute_includes out, rejected_url
      assert_includes out, runs.length == 2 ? 'in flight' : 'verdict unknown'
      assert_includes out, URL_RELEASE_RUN if runs.length == 2
    end
  end

  def test_row10_each_primary_filter_prevents_a_false_404_alarm
    primary = { headBranch: 'main', event: 'push', headSha: SHA_VERSION_HEAD,
                conclusion: nil, url: URL_RELEASE_RUN }
    # Separate decoys make each filter necessary independently of the other.
    retry_url = "#{URL_RELEASE_RUN}1"
    off_main_url = "#{URL_RELEASE_RUN}2"
    decoys = [primary.merge(event: 'workflow_dispatch', conclusion: 'failure', url: retry_url),
              primary.merge(headBranch: 'topic', conclusion: 'failure', url: off_main_url)]

    runs = JSON.generate([*decoys, primary])
    out, err, status = run_row10(http_status: 404, release_run: runs)

    assert_predicate status, :success?, err
    assert_includes out, 'in flight'
    assert_includes out, URL_RELEASE_RUN
    refute_includes out, retry_url
    refute_includes out, off_main_url
    refute_includes out, 'Unhealthy'

    ['--branch main ', '--event push '].each do |filter|
      command = row10_command.sub(filter, '')

      refute_equal row10_command, command
      out, err, status = run_row10(http_status: 404, release_run: runs, command: command)

      assert_predicate status, :success?, err
      assert_includes out, 'Unhealthy', "removing #{filter} must expose the false alarm"
      assert_includes out, 'release did not publish'
      assert_includes out, filter == '--branch main ' ? off_main_url : retry_url
    end
  end

  def test_row10_http_404_with_an_unreadable_release_run_fails_closed
    out, err, _status = run_row10(http_status: 404, gh_fail: true)

    refute_includes out, 'Unhealthy',
                    'the release-run read failed, so the row cannot tell an in-flight ' \
                    'release from a missing one — grading Unhealthy would file a false ask ' \
                    'against a release that is still propagating; ' \
                    "got stdout=#{out.inspect}, stderr=#{err.inspect}"

    assert_includes out, 'verdict unknown',
                    'an unreadable run list beside a 404 must fail closed, the same rule ' \
                    "rows 8, 9, 11 and 12 use; got stdout=#{out.inspect}"

    assert_includes out, rubygems_version,
                    '`verdict unknown` must still name the version it could not grade; ' \
                    "got stdout=#{out.inspect}"
  end

  def test_row10_http_5xx_is_probe_failure_not_a_verdict
    out, _err, status = run_row10(http_status: 503)

    assert_predicate status, :success?,
                     "row 10's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'verdict unknown',
                    'a 5xx is probe failure, not evidence the version is absent — ' \
                    'RELEASE.md grades it retry-and-re-run, never red; ' \
                    "got stdout=#{out.inspect}"

    refute_includes out, 'Unhealthy',
                    'a 5xx says nothing about whether the version exists'
    refute_includes out, 'success',
                    'anything but HTTP 200 is not a served version'
  end

  def test_row10_transport_failure_is_probe_failure_not_a_verdict
    out, _err, status = run_row10(http_status: '000')

    assert_predicate status, :success?,
                     "row 10's command must run cleanly (status=#{status.inspect})"

    assert_includes out, 'verdict unknown',
                    'a transport failure carries no HTTP status at all — it is probe ' \
                    'failure, not evidence the version is absent; ' \
                    "got stdout=#{out.inspect}"

    refute_includes out, 'Unhealthy',
                    'no HTTP status is not evidence the version is absent'
    refute_includes out, 'success',
                    'anything but HTTP 200 is not a served version'
  end

  def test_row10_captures_the_status_instead_of_letting_curl_fail_on_http_errors
    command = row10_command

    assert_match(/-w '%\{http_code\}'/, command,
                 'row 10 must capture the HTTP status: grading curl\'s exit code alone ' \
                 'collapses a 404 and a dead network into one non-zero exit')

    refute_match(/curl\s+-\w*f/, command,
                 'the row must not run curl with `-f`: a 404 then exits non-zero and lands ' \
                 'in the probe-failure arm, so a missing release can never grade Unhealthy — ' \
                 'the exact defect this block exists to keep out')
  end

  # The `Command` cell of the 'RubyGems serves' row: the second backtick span
  # on the row (the first is the `Wurk::VERSION` in its Signal cell). `\|` is
  # markdown's escape for a literal pipe inside a table cell, unescaped here
  # exactly as health_brief_test.rb's command_cell does.
  def row10_command
    row = health_rubygems_row

    spans = row.scan(/`([^`]*)`/).map(&:first)
    raise "the 'RubyGems serves' row carries no backticked command cell" if spans.length < 2

    spans[1].gsub('\\|', '|')
  end

  # The `RubyGems serves `Wurk::VERSION`` row, found by its Signal cell:
  # another row's Healthy cell can carry the same words, and a lookup that
  # grabs the first line mentioning them reads the wrong row's command.
  def health_rubygems_row
    row = File.read(HEALTH_BRIEF).lines.find { |line| line.include?('RubyGems serves `Wurk::VERSION`') }
    raise "health.md has no 'RubyGems serves Wurk::VERSION' row" if row.nil?

    row
  end

  def rubygems_version
    version = File.read(File.join(ROOT, 'lib', 'wurk', 'version.rb'))[/VERSION = '([^']+)'/, 1]
    raise 'lib/wurk/version.rb must define VERSION' if version.nil?

    version
  end

  # Runs the row's extracted command from the repo root with the stub curl and
  # gh first on PATH, so the probe answers from $WURK_TEST_HTTP_STATUS and the
  # release-run read from $WURK_TEST_RELEASE_RUN instead of the network.
  # version_at_head: :repo serves the checkout's own lib/wurk/version.rb at
  # the version-carrying commit; a String serves those bytes; nil serves
  # nothing, so the contents read fails the way a rate limit or a 4xx would.
  def run_row10(http_status:, release_run: nil, gh_fail: false, version_at_head: :repo, command: nil)
    command ||= row10_command
    if release_run
      release_run = JSON.generate(JSON.parse(release_run).map do |run|
        { 'headBranch' => 'main', 'event' => 'push' }.merge(run)
      end)
    end
    at_head =
      case version_at_head
      when :repo then File.read(File.join(ROOT, 'lib', 'wurk', 'version.rb'))
      when String then version_at_head
      else ''
      end
    Dir.mktmpdir('wurk-row10-') do |tmpdir|
      bin_dir = File.join(tmpdir, 'bin')
      Dir.mkdir(bin_dir)

      { 'curl' => STUB_CURL, 'gh' => STUB_GH_ROW10 }.each do |name, body|
        path = File.join(bin_dir, name)
        File.write(path, body)
        File.chmod(0o755, path)
      end

      env = {
        'PATH' => "#{bin_dir}:#{ENV.fetch('PATH', '')}",
        'WURK_TEST_HTTP_STATUS' => http_status.to_s,
        'WURK_TEST_RELEASE_RUN' => release_run.to_s,
        'WURK_TEST_VERSION_SHA' => SHA_VERSION_HEAD,
        'WURK_TEST_VERSION_AT_HEAD' => at_head,
        'WURK_TEST_GH_FAIL' => gh_fail ? '1' : '0'
      }

      Open3.capture3(env, 'bash', '-c', command, chdir: ROOT)
    end
  end

  # The RELEASE.md block between the 'Verifying a release actually shipped'
  # heading and the next heading of any level.
  def verifying_section(text)
    lines = text.lines
    first = lines.index { |l| l.start_with?('### Verifying a release actually shipped') }
    return nil unless first

    last = ((first + 1)...lines.size).find { |i| lines[i].start_with?('#') } || lines.size
    lines[first...last].join
  end

  # Stub curl, faithful for the flags row 10 uses: -s/-S are accepted and
  # ignored, -o discards the body, -w FORMAT is honoured with the real
  # %{http_code} semantics, and -f turns a 4xx/5xx into exit 22 — so a
  # regression that re-adds `-f` fails these tests the way the defect shipped.
  # The HTTP status comes from $WURK_TEST_HTTP_STATUS; 000 simulates a
  # transport failure (diagnostic on stderr, exit 7). The status is served
  # only for the version carried by $WURK_TEST_VERSION_AT_HEAD — the file at
  # the resolved commit; a URL for any other version is one RubyGems does
  # not serve, so it answers 404 (with -f's exit 22), which keeps the
  # version binding falsifiable.
  STUB_CURL = <<~'SHELL'
    #!/usr/bin/env bash
    status="$WURK_TEST_HTTP_STATUS"
    want_fail=""
    fmt=""
    asked=""
    prev=""
    for arg in "$@"; do
      case "$prev" in
        -w) fmt="$arg" ;;
      esac
      case "$arg" in
        -f) want_fail=1 ;;
        -w) ;;
        */versions/*.json)
          tail="${arg##*/versions/}"
          asked="${tail%.json}"
          ;;
      esac
      prev="$arg"
    done
    if [ "$status" = "000" ]; then
      printf 'curl: (7) Failed to connect to rubygems.org port 443\n' >&2
      if [ -n "$fmt" ]; then printf '000'; fi
      exit 7
    fi
    if [ -n "$asked" ] && [ -n "$WURK_TEST_VERSION_AT_HEAD" ]; then
      served="$(printf '%s\n' "$WURK_TEST_VERSION_AT_HEAD" | grep -oE "["'][0-9][^"']*["']" | head -1 | tr -d "\"'")"
      if [ -n "$served" ] && [ "$asked" != "$served" ]; then
        status=404
      fi
    fi
    if [ -n "$fmt" ]; then printf '%s' "$status"; fi
    case "$status" in
      2*) exit 0 ;;
      *)
        if [ -n "$want_fail" ]; then
          printf 'curl: (22) The requested URL returned error: %s\n' "$status" >&2
          exit 22
        fi
        exit 0
        ;;
    esac
  SHELL

  # Stub gh: answers the three reads row 10 makes — the version's own commit
  # (`gh api .../commits?path=lib/wurk/version.rb...`), the file AT that
  # commit (`gh api .../contents/lib/wurk/version.rb?ref=<sha>` — the
  # version of record, not the checkout's own copy), and the release.yml
  # primary main-push run BOUND to it (branch, event and commit filters).
  # Branch/event filters select from newest-first fixtures, just as gh does.
  # The run list is served only for the version's own sha: a row that
  # dropped the --commit filter would be reading the newest run of any shape,
  # which says nothing about this version, so the stub refuses to answer it.
  # Anything else exits 1, so a regression that reaches for gh on another
  # path cannot pass by reusing this fixture; WURK_TEST_GH_FAIL=1 breaks
  # exactly the run read.
  STUB_GH_ROW10 = <<~'SHELL'
    #!/usr/bin/env bash
    if [ "${1:-}" = "api" ]; then
      for arg in "$@"; do
        case "$arg" in
          *"contents/lib/wurk/version.rb"*)
            if [ -z "$WURK_TEST_VERSION_AT_HEAD" ]; then
              printf 'stub gh api: no version-at-head payload for %s\n' "$arg" >&2
              exit 1
            fi
            printf '%s\n' "$WURK_TEST_VERSION_AT_HEAD"
            exit 0
            ;;
          *lib/wurk/version.rb*)
            printf '[{"sha":"%s"}]\n' "$WURK_TEST_VERSION_SHA"
            exit 0
            ;;
        esac
      done
      printf 'stub gh api: unexpected path: %s\n' "$*" >&2
      exit 1
    fi
    if [ "${1:-}" = "run" ] && [ "${2:-}" = "list" ]; then
      if [ "$WURK_TEST_GH_FAIL" = "1" ]; then
        printf 'stub gh run list: the read fails on purpose (rate limited or 4xx)\n' >&2
        exit 1
      fi
      commit=""
      branch=""
      event=""
      prev=""
      for arg in "$@"; do
        case "$prev" in
          --commit) commit="$arg" ;;
          --branch) branch="$arg" ;;
          --event) event="$arg" ;;
        esac
        prev="$arg"
      done
      if [ -z "$commit" ]; then
        printf 'stub gh run list: no --commit filter in: %s\n' "$*" >&2
        exit 1
      fi
      if [ "$commit" != "$WURK_TEST_VERSION_SHA" ]; then
        printf 'stub gh run list: no run for commit %s (the version own sha is %s)\n' \
          "$commit" "$WURK_TEST_VERSION_SHA" >&2
        exit 1
      fi
      printf '%s' "$WURK_TEST_RELEASE_RUN" | jq --arg commit "$commit" --arg branch "$branch" --arg event "$event" \
        '[.[] | select(($commit == "" or .headSha == $commit)
          and ($branch == "" or .headBranch == $branch)
          and ($event == "" or .event == $event))] | .[:1]'
      exit 0
    fi
    printf 'stub gh: unexpected command: %s\n' "$*" >&2
    exit 1
  SHELL

  BRIEF_RANGE = /RELEASE\.md:(\d+)-(\d+)/

  def brief_release_md_anchor
    match = BRIEF_RANGE.match(File.read(BRIEF))
    return nil unless match

    { first: match[1].to_i, last: match[2].to_i }
  end
end
