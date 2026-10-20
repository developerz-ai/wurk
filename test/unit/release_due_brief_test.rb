# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'
require 'tmpdir'

# Guards the Window/Do table in .dz/briefs/release-due.md the same way
# claude_md_claims_test.rb gates CLAUDE.md: a steering brief the day of
# "Decide" runs without an object store must not silently collapse a
# missing window to "empty -> nothing". The Day loop runs the brief on
# worktree-only checkouts too; if the git commands cannot run there, the
# verdict is "unknown", and that hidden absence is the regression this gate
# pins. Reads files and touches no Redis or shared state.
class ReleaseDueBriefTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  BRIEF = File.join(ROOT, '.dz', 'briefs', 'release-due.md')

  # A row's cells are `|`-separated; the second cell is the "Do" verdict.
  # The header separator (`|---|`) is excluded by requiring at least one
  # letter on each side of the second `|`.
  ROW_RE = /\A\| (?<window>[^|]+) \|(?<do>[^|]+) \|\z/

  def setup
    @text = File.read(BRIEF)
  end

  def test_unknown_row_present_for_unreadable_window
    unknown_rows = unknown_rows_in_table

    refute_empty unknown_rows,
                 '.dz/briefs/release-due.md Window/Do table must contain a row whose ' \
                 'Do cell starts with the word "unknown" so a failure to read the ' \
                 'window is surfaced instead of collapsed to "nothing"'

    missing_window_rows = unknown_rows.reject do |row|
      row[:window].match?(/worktree-only|no object store|cannot run|fail/i)
    end

    assert_empty missing_window_rows,
                 'these rows say "unknown" without naming the unreadable-window case ' \
                 '(worktree-only .git / no object store): ' \
                 "#{missing_window_rows.map { |r| r[:raw] }.join('; ')}"
  end

  def test_unknown_row_does_not_say_nothing
    unknown_rows = unknown_rows_in_table

    saying_nothing = unknown_rows.select { |row| row[:do].match?(/\bnothing\b/) }

    assert_empty saying_nothing,
                 'the unknown-verdict row must not also say "nothing"; ' \
                 'otherwise the missing-window case is silently collapsed: ' \
                 "#{saying_nothing.map { |r| r[:raw] }.join('; ')}"
  end

  def test_unknown_row_is_not_the_empty_row
    empty_row_with_unknown = parse_table_rows.find do |row|
      row[:window] == 'empty' && row[:do].start_with?('unknown')
    end

    assert_nil empty_row_with_unknown,
               'the empty-window row must keep its "nothing" verdict; an ' \
               '"unknown" verdict belongs on its own row, not on the empty row'
  end

  def test_unknown_token_lives_on_a_single_stable_table_row
    # grep -n "unknown" must point at the unknown-verdict row, not at
    # prose elsewhere in the brief. A future edit that drops the row
    # (or scatters the token across multiple lines) breaks this gate.
    occurrences = @text.lines.each_with_index.select { |line, _| line.include?('unknown') }

    assert_equal 1, occurrences.size,
                 '"unknown" must appear exactly once in the brief; found ' \
                 "#{occurrences.size} at line(s) #{occurrences.map { |_, i| i + 1 }.join(', ')}"

    line, lineno = occurrences.first
    line_no = lineno + 1

    assert line.strip.match?(ROW_RE) && table_line?(line_no),
           "the single \"unknown\" occurrence (line #{line_no}) must be the " \
           'unknown-verdict table row, not prose elsewhere'
  end

  def test_compare_response_extracted_via_jq_in_current_shell
    decide_block = extract_decide_block

    # The Compare response must be filtered through `jq` to drive the
    # while loop's SHA stream — an un-filtered response would not
    # expose the `.commits[]` anchors the per-commit path filter walks,
    # so row-1's "empty" verdict and row-5's `<next>` cue would both be
    # unreachable. The extraction lives in the CURRENT shell (not as
    # part of a `< <(...)` process substitution piped into the loop)
    # so a failed Compare aborts the script instead of letting the
    # loop run with no input.
    assert_match(
      %r{compare/[^\s"]+},
      decide_block,
      'the Compare endpoint `compare/$last...main` must be referenced'
    )
    assert_match(
      /\.commits\[\]\.sha/,
      decide_block,
      'the Compare response must be filtered via `jq -r ".commits[].sha"`'
    )
  end

  def test_per_commit_jq_filter_emits_only_commits_touching_ship_spec_paths
    per_commit_filter = extract_per_commit_jq_filter

    refute_nil per_commit_filter,
               '.dz/briefs/release-due.md must contain a per-commit jq filter ' \
               '(a `jq -r` invocation after `gh api ".../commits/$sha"`) so ' \
               'the window is anchored on a per-commit `.files[]` check ' \
               "rather than Compare's aggregate `.files[]`"

    # The filter must reference `.files[]` and `.filename` — its inputs are a
    # single commit's GitHub API response, not Compare's aggregate response.
    assert_match(/\.files\b/, per_commit_filter,
                 'the per-commit filter must reference `.files[]` from the ' \
                 'single-commit API response')
    assert_match(/\bfilename\b/, per_commit_filter,
                 'the per-commit filter must extract `.filename` from each ' \
                 '.files[] entry')

    # Each of the seven ship-spec paths (the local fast path's git pathspecs,
    # which the brief transcribes into jq-regex form) must trigger emission
    # when present in a commit's per-commit `.files[]`. Drive the real jq
    # against a JSON fixture shaped like one commit's API response so the
    # assertions exercise the filter as it actually runs — substring matches
    # would accept the jq-invalid `\.` escape AND reject the valid `\\.`
    # replacement, which is the regression this test pins.
    shipping_paths = {
      'lib/**/*.rb' => 'lib/foo.rb',
      'lib/**/*.lua' => 'lib/foo.lua',
      'app/**/*.rb' => 'app/foo.rb',
      'config/**' => 'config/foo.yml',
      'exe/*' => 'exe/wurk',
      'frontend/src/**' => 'frontend/src/index.tsx',
      'wurk.gemspec' => 'wurk.gemspec'
    }

    shipping_paths.each do |pathspec, sample|
      fixture = JSON.generate(
        sha: 'a' * 40,
        commit: {
          committer: { date: '2026-01-15T10:00:00Z' },
          message: "feat: shipping #{pathspec}\n\nbody"
        },
        files: [{ filename: sample }]
      )

      out, err, status = run_jq(per_commit_filter, fixture)

      assert_predicate status, :success?,
                       "jq filter must compile and run for ship-spec path `#{pathspec}`: #{err}"

      # Assert the exact output row — `<7-sha> <date> <first line>` — rather
      # than a substring of the message and a substring of the SHA. A filter
      # that emitted an empty date or appended the commit body would still
      # pass the substring checks; only the exact-row check pins the row
      # shape the `<next>` classifier depends on.
      expected_row = "#{'a' * 7} 2026-01-15T10:00:00Z feat: shipping #{pathspec}"

      assert_equal expected_row, out.strip,
                   "commit touching ship-spec path `#{pathspec}` must emit " \
                   'exact row `<7-sha> <date> <first line>`, not the message body'
    end

    # A docs-only commit (only non-ship-spec files in its per-commit diff)
    # must NOT be emitted — otherwise a docs-only `feat` would dominate the
    # `<next>` classification alongside a real Ruby fix.
    docs_fixture = JSON.generate(
      sha: 'b' * 40,
      commit: {
        committer: { date: '2026-01-15T11:00:00Z' },
        message: 'docs: typo'
      },
      files: [{ filename: 'README.md' }, { filename: 'CHANGELOG.md' }]
    )
    out, err, status = run_jq(per_commit_filter, docs_fixture)

    assert_predicate status, :success?, "jq filter must compile and run for docs-only fixture: #{err}"
    assert_equal '', out.strip,
                 'docs-only commit must NOT be emitted (no ship-spec path touched)'

    # A commit with no `.files[]` at all (e.g. a revert whose per-commit
    # diff is empty once aggregated, or any commit the API returns files=null
    # for) must NOT be emitted — the filter is `(.files // [])`, so a null
    # `.files` becomes an empty array.
    no_files_fixture = JSON.generate(
      sha: 'c' * 40,
      commit: {
        committer: { date: '2026-01-15T12:00:00Z' },
        message: 'feat: revert'
      },
      files: []
    )
    out, err, status = run_jq(per_commit_filter, no_files_fixture)

    assert_predicate status, :success?, "jq filter must compile and run for empty-files fixture: #{err}"
    assert_equal '', out.strip,
                 'commit with no files must NOT be emitted'

    # The revert scenario: a commit whose per-commit `.files[]` includes a
    # shipping path must be emitted even when an earlier commit in the same
    # window reverted those exact changes (Compare's aggregate `.files[]`
    # would miss this — net zero changes leave the file out of the net diff).
    revert_fixture = JSON.generate(
      sha: 'd' * 40,
      commit: {
        committer: { date: '2026-01-15T13:00:00Z' },
        message: 'Revert "feat: add new method"'
      },
      files: [{ filename: 'lib/foo.rb', additions: 0, deletions: 5 }]
    )
    out, err, status = run_jq(per_commit_filter, revert_fixture)

    assert_predicate status, :success?, "jq filter must compile and run for revert fixture: #{err}"
    assert_includes out, 'Revert "feat: add new method"',
                    'revert commit that per-commit touched `lib/foo.rb` must be emitted'
  end

  def test_jq_filter_extracts_per_commit_dates_and_first_line_subjects
    decide_block = extract_decide_block

    # Per-commit iteration: `.commits[]` produces a stream of commits;
    # `.commit.committer.date` then extracts each commit's committer
    # date. Together these form the `.commits[].commit.committer.date`
    # access the brief describes — they don't have to appear as a
    # contiguous literal in the jq filter (the typical jq form splits
    # them across the iteration and the field access).
    assert_match(/\.commits\[\]/, decide_block,
                 'per-commit iteration must come from `.commits[]`')

    assert_match(/\.commit\.committer\.date/, decide_block,
                 'per-commit dates must come from `.commit.committer.date` ' \
                 '(after `.commits[]` iteration)')

    # Commit subjects come from `.commit.message`.
    assert_match(/\.commit\.message/, decide_block,
                 'commit subjects must come from `.commit.message` so ' \
                 "row 5's `<next>` cue can classify them")

    # The first-line subject is extracted via something like
    # `split("\n")[0]`, so each row's subject is the conventional first
    # line of the commit message, not the body.
    assert_match(/split\("\\n"\)\[0\]/, decide_block,
                 'the first line of `.commit.message` must be ' \
                 'emitted via `split("\\n")[0]` so each row\'s subject is ' \
                 'the conventional first line, not the body')
  end

  def test_brief_notes_since_is_not_a_substitute_for_compare
    decide_block = extract_decide_block

    # The brief must mention `since=<release-date>` in the context of the
    # Compare endpoint — otherwise a future edit could silently swap the
    # Compare call for the commits-list endpoint and lose the row-1
    # "empty" verdict's anchor to $last.
    assert_match(/since/, decide_block,
                 'the brief must mention `since=` in the context of the ' \
                 'Compare endpoint to note it is not a substitute')

    # And it must convey "not a substitute" — bare `since=` is not enough.
    assert_match(/not\s+a?\s*substitute/i, decide_block,
                 'the brief must explicitly note that `since=<release-date>` ' \
                 'is not a substitute for the Compare endpoint')
  end

  def test_per_commit_gh_api_failure_aborts_decision
    decide_block = extract_decide_block

    # A rate-limited or 4xx `gh api .../commits/$sha` returns an error
    # object without `.files[]`. The filter's `(.files // [])` would then
    # yield an empty array, silently dropping the commit — so a shipping
    # commit would NOT be reported, and the agent would treat the window
    # as smaller than it is. The per-commit call must be guarded by an
    # exit-status check that aborts the Decide script on failure rather
    # than accepting an incomplete window.
    assert_match(
      %r{if\s+!.*?commits/\$\{?sha\}?}m,
      decide_block,
      'the per-commit `gh api .../commits/$sha` call must be guarded by an ' \
      '`if ! ...` exit-status check so a failure aborts the decision'
    )
    assert_match(
      /exit\s+1/,
      decide_block,
      'the failure branch must `exit 1` so the abort propagates to the ' \
      'Decide script (not just the per-commit subshell)'
    )
  end

  # End-to-end execution check that pins the abort-propagation contract the
  # text-pattern assertions above cannot: a `| cmd | while read` would run
  # the loop in a subshell, where `exit 1` exits only the subshell, and the
  # Decide script continues into the local fast path. Run the extracted
  # Bash against stub `gh` and `git` binaries, point the per-commit stub
  # at failure, and assert the script aborts BEFORE the local fast path's
  # first git command. The text-pattern test above still passes if a future
  # edit pipes the SHA stream into the loop instead of using a here-string;
  # only this execution-based test catches the regression.
  def test_per_commit_gh_api_failure_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: per_commit_failing_stub_gh,
      failing_curl: 'the per-commit `gh api commits/<sha>` stub fails',
      failure_message: 'per-commit `gh api commits/<sha>` failure must abort the Decide script',
      # The brief's per-commit diagnostic expands `$sha` to the actual
      # commit SHA at runtime, so pin the SHA-stable tail of the line.
      expected_stderr: 'aborting rather than treating a missing commit as not-shipping'
    )
  end

  # Same contract for the Compare request itself: if Compare fails (or its
  # SHA extraction fails), the script must abort before the local fast path
  # — not let the loop run with no input and report an empty window. This
  # is the structural contract the brief's Compare pre-validation enforces.
  def test_compare_request_failure_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: compare_failing_stub_gh,
      failing_curl: 'the Compare `gh api compare/...` stub fails',
      failure_message: 'Compare request failure must abort the Decide script',
      expected_stderr: 'ERROR: Compare request for'
    )
  end

  # The window's RIGHT bound is `origin/main`, and nothing else in the Decide
  # block updates refs/remotes/origin/main — so without a fetch that moves
  # refs/heads/main onto it, the right bound is whatever the clone last
  # fetched. Commits merged since then are invisible, every git command still
  # succeeds, and the window reads empty: a release that is due is reported as
  # "nothing" with no error anywhere to notice. Position, not presence, is
  # what this test pins — a fetch placed after the `git log`, or a `git
  # describe` that ran before it, leaves the same stale right bound while
  # satisfying every other assertion in this file.
  def test_main_fetch_precedes_describe_and_the_log_window
    decide_block = extract_decide_block

    fetch_at = decide_block.index(%r{^git fetch[^\n]*'\+refs/heads/main:refs/remotes/origin/main'})

    refute_nil fetch_at,
               'the local fast path must fetch `main` with an explicit ' \
               "'+refs/heads/main:refs/remotes/origin/main' refspec; no other " \
               'command in the Decide block updates refs/remotes/origin/main, so ' \
               "without it the window's right bound stays at whatever the clone " \
               'last fetched and merged commits are invisible'

    describe_at = decide_block.index(/^local_last=\$\(git describe\b/)

    refute_nil describe_at,
               'the local fast path must still resolve the last tag locally with ' \
               '`git describe ... origin/main`'

    log_at = decide_block.index(/^git log\b/)

    refute_nil log_at,
               'the local fast path must still window with `git log "$last"..origin/main`'

    assert_operator fetch_at, :<, describe_at,
                    'the `origin/main` fetch must run BEFORE `git describe`, which ' \
                    'reads the very ref the fetch refreshes'

    assert_operator fetch_at, :<, log_at,
                    'the `origin/main` fetch must run BEFORE the `git log "$last"..origin/main` ' \
                    'window, or the right bound is stale and the window reads empty'
  end

  # The text-pattern test above cannot tell a GUARDED fetch from a bare one:
  # with a bare `git fetch`, a failing fetch leaves the block to run `git log`
  # against whatever origin/main the clone already had — the empty-window
  # "nothing" verdict — with only git's own error text to notice. Drive the
  # real block against a `git` stub that fails `fetch` and still writes the
  # fast-path marker on `describe`: the abort must land before that runs.
  def test_main_fetch_failure_aborts_decision_before_local_fast_path
    assert_decide_aborts_before_local_fast_path(
      stub_gh: empty_compare_stub_gh,
      stub_git: fetch_failing_stub_git,
      failing_curl: 'the `git fetch` stub fails',
      failure_message: 'a failing `git fetch` in the local fast path must abort the Decide script',
      expected_stderr: 'ERROR: fetching'
    )
  end

  # Empty Compare response (`{"commits":[]}`) must surface as a clean
  # empty window — the loop is fed by a here-string `<<<"$compare_shas"`,
  # which still supplies one blank line for an empty variable, and `read`
  # would consume it as `sha=""`. Without the `[[ -z "$sha" ]]` guard,
  # the per-commit call would request `gh api repos/.../commits/` (no
  # SHA) and abort on a 404 unrelated to the actual decision. Drive the
  # bash against a stub `gh` whose Compare endpoint returns an empty
  # commits list and whose per-commit branch prints `PER_COMMIT_CALLED`
  # to stderr before exiting 1. The success-status assertion catches a
  # here-string regression that lets the 404 bubble up to the script;
  # the stderr-PER_COMMIT_CALLED assertion catches the pipeline-into-
  # while regression where the per-commit subshell exits but the outer
  # script continues with status 0. Together they pin that the per-commit
  # loop never iterates a blank SHA, no matter how the SHA stream is
  # shaped. The brief's local fast path uses the marker-writing `git`
  # stub so real `git` doesn't leak real commits into stdout and mask a
  # regression by inflating the row count the assert has to compare
  # against.
  def test_empty_compare_response_runs_cleanly
    run_decide_under_stubs(empty_compare_stub_gh) do |(out, err, status), _tmpdir|
      assert_predicate status, :success?,
                       'empty Compare response must run cleanly ' \
                       "(status=#{status.inspect}, stdout=#{out.inspect}, " \
                       "stderr=#{err.inspect}); the [[ -z \"$sha\" ]] guard " \
                       'inside the while loop must skip the blank SHA ' \
                       'produced by `<<<"$compare_shas"` for an empty SHA stream'

      refute_match(/PER_COMMIT_CALLED/, err,
                   'empty Compare must not call `gh api .../commits/<sha>`; ' \
                   'the stub emitted PER_COMMIT_CALLED on stderr when its ' \
                   'per-commit branch fired, which means the [[ -z "$sha" ]] ' \
                   "guard is missing — stderr=#{err.inspect}")

      # No commit row (the `<7-sha> <date> <first-line>` shape the
      # per-commit loop emits) should be present — the per-commit loop
      # must terminate without iterating the blank SHA. The brief's
      # un-captured `gh api .../git/ref/tags/$last` and `gh release
      # view` verify calls both return `{}` from the stub, so the only
      # stdout the script emits is those two `{}` lines.
      lines = out.lines.map(&:chomp).reject(&:empty?)

      assert_equal ['{}', '{}'], lines,
                   'empty Compare response must produce only the two ' \
                   'un-captured `{}` responses from the tag/ref and ' \
                   'release verify calls on stdout; any other line is ' \
                   'a regression in the per-commit loop'

      refute lines.any? { |line| line.match?(/\A[0-9a-f]{7} /) },
             'no line of stdout should be a per-commit row shaped like ' \
             '`<7-sha> <date> <first line>` — an empty Compare response ' \
             'means the per-commit loop must not iterate any SHA at all'
    end
  end

  def test_matching_refs_tags_call_paginates
    # `gh api` paginates only with --paginate; a repo past the page-1
    # tag cap resolves $last against only the first page and `tail -1`
    # lands on whatever that page happens to end with. The Day loop
    # relies on $last being the canonical latest, so the flag is the
    # guard against a silently stale $last.
    block = matching_refs_tags_block

    refute_nil block,
               'expected a `gh api .../git/matching-refs/tags/` call in ' \
               '.dz/briefs/release-due.md to gate against a stale $last'

    assert_includes block, '--paginate',
                    'the matching-refs/tags gh api call must carry --paginate so ' \
                    'a tag-heavy repo does not silently resolve $last to a stale ' \
                    'first-page tag'
  end

  def test_no_hardcoded_last_resolves_prose
    # A `$last (currently) resolves to vX.Y.Z` line ages the moment a
    # release ships; the canonical $last resolution lives in the gh api
    # call above it, not in a stale version constant. Pin the absence
    # so future edits cannot reintroduce the practice.
    offenders = @text.lines.each_with_index.filter_map do |line, idx|
      idx if line.match?(/\$last\b[^\n]*\bresolves?\s+to\s+v\d+\.\d+\.\d+/)
    end

    assert_empty offenders,
                 'the brief must not hard-code `$last (currently) resolves to vX.Y.Z`; ' \
                 'offending line numbers: ' +
                 (offenders.empty? ? 'none' : offenders.map { |i| "L#{i + 1}" }.join(', '))
  end

  private

  # The per-commit filter is the `jq -r '...'` invocation immediately after
  # `gh api ".../commits/$sha"` in the Decide block — its input is a single
  # commit's API response (with per-commit `.files[]`), not Compare's
  # aggregate response. A regex with the `m` flag is enough: the filter has
  # no single quotes inside its body, so the closing `'` of the bash string
  # unambiguously terminates it.
  def extract_per_commit_jq_filter
    decide_block = extract_decide_block
    match = decide_block.match(%r{commits/\$sha.*?jq\s+-r\s+'(.+?)'}m)
    match && match[1]
  end

  # Run the given jq filter against `input` (a JSON string) and capture its
  # stdout/stderr/exit-status. Returns [stdout, stderr, status].
  def run_jq(filter, input)
    Open3.capture3('jq', '-r', filter, stdin_data: input)
  end

  # Stub `gh` whose per-commit `gh api .../commits/<sha>` call always
  # fails. Compare, the tag lookup, the ref verification, and `gh release
  # view` succeed with the minimum response shape the brief's jq path
  # expects, so the script reaches the while loop and a single commit
  # passes through the SHA stream — only the per-commit fetch is broken.
  PER_COMMIT_FAILING_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        url="${1:-}"
        case "$url" in
          *git/matching-refs/tags/*)
            printf '%s\n' '[{"ref":"refs/tags/v1.8.0"}]'
            ;;
          *git/ref/tags/v1.8.0)
            printf '%s\n' '{}'
            ;;
          *compare/v1.8.0...main)
            printf '%s\n' '{"commits":[{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
            ;;
          *commits/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
            printf 'ERROR: stub gh api commits/aaa failed (rate-limited or 4xx)\n' >&2
            exit 1
            ;;
          *)
            printf 'ERROR: stub gh api: unexpected URL: %s\n' "$url" >&2
            exit 1
            ;;
        esac
        ;;
      release)
        printf '%s\n' '{}'
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :PER_COMMIT_FAILING_STUB_GH

  # Stub `gh` whose Compare `gh api .../compare/<last>...main` call
  # always fails. Every other endpoint succeeds, so a regression that
  # silently lets Compare fail (the original `< <(...)` bug) would let
  # the while loop run with no input, fall through to the local fast
  # path, and the marker below would catch it.
  COMPARE_FAILING_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        url="${1:-}"
        case "$url" in
          *git/matching-refs/tags/*)
            printf '%s\n' '[{"ref":"refs/tags/v1.8.0"}]'
            ;;
          *git/ref/tags/v1.8.0)
            printf '%s\n' '{}'
            ;;
          *compare/v1.8.0...main)
            printf 'ERROR: stub gh api compare/v1.8.0...main failed (rate-limited or 4xx)\n' >&2
            exit 1
            ;;
          *)
            printf 'ERROR: stub gh api: unexpected URL: %s\n' "$url" >&2
            exit 1
            ;;
        esac
        ;;
      release)
        printf '%s\n' '{}'
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :COMPARE_FAILING_STUB_GH

  # Stub `gh` whose Compare response is `{"commits":[]}`. Every other
  # endpoint succeeds, so the brief bash reaches the per-commit loop
  # with an empty SHA stream. A per-commit call is a regression —
  # `<<<"$empty_var"` still feeds the loop a blank line and `read`
  # would consume it as `sha=""`, so the [[ -z "$sha" ]] guard is
  # what surfaces the empty window cleanly. The per-commit branch
  # prints `PER_COMMIT_CALLED` to stderr and exits 1, so a regression
  # that drops the guard surfaces via BOTH the script's exit status
  # (caught by `assert status.success?`) AND a unique substring on
  # stderr (caught by `refute_match /PER_COMMIT_CALLED/, err`) — the
  # second gate catches the pipeline-into-while regression where the
  # subshell exit leaves the script running with status 0.
  EMPTY_COMPARE_STUB_GH = <<~'SHELL'
    #!/usr/bin/env bash
    case "$1" in
      api)
        shift
        url="${1:-}"
        case "$url" in
          *git/matching-refs/tags/*)
            printf '%s\n' '[{"ref":"refs/tags/v1.8.0"}]'
            ;;
          *git/ref/tags/v1.8.0)
            printf '%s\n' '{}'
            ;;
          *compare/v1.8.0...main)
            printf '%s\n' '{"commits":[]}'
            ;;
          *commits/*)
            printf 'PER_COMMIT_CALLED\n' >&2
            printf 'ERROR: stub gh api: per-commit endpoint must not be called for an empty Compare response\n' >&2
            exit 1
            ;;
          *)
            printf 'ERROR: stub gh api: unexpected URL: %s\n' "$url" >&2
            exit 1
            ;;
        esac
        ;;
      release)
        printf '%s\n' '{}'
        ;;
      *)
        printf 'ERROR: stub gh: unexpected command: %s\n' "$*" >&2
        exit 1
        ;;
    esac
  SHELL
  private_constant :EMPTY_COMPARE_STUB_GH

  # Stub `git` whose `describe` invocation writes a marker file. Every
  # other subcommand is a silent success — the brief's bash reads only
  # `describe`/`fetch`/`log`, and the marker is the signal the test
  # uses to detect whether the Decide script reached the local fast
  # path before aborting.
  STUB_GIT = <<~'SHELL'
    #!/usr/bin/env bash
    if [[ "$1" == "describe" ]]; then
      printf 'LOCAL_FAST_PATH_REACHED\n' > "$WURK_TEST_FAST_PATH_MARKER"
    fi
    exit 0
  SHELL
  private_constant :STUB_GIT

  # Stub `git` whose `fetch` invocation always fails. `describe` still writes
  # the fast-path marker, so the abort test can tell "the fetch failed and the
  # script stopped" from "the fetch failed and the script windowed a stale
  # origin/main anyway". The stderr line deliberately avoids the word ERROR:
  # the assertion on the brief's diagnostic must not be satisfiable by this
  # stub's own noise.
  FETCH_FAILING_STUB_GIT = <<~'SHELL'
    #!/usr/bin/env bash
    if [[ "$1" == "fetch" ]]; then
      printf 'stub git fetch: failing on purpose\n' >&2
      exit 1
    fi
    if [[ "$1" == "describe" ]]; then
      printf 'LOCAL_FAST_PATH_REACHED\n' > "$WURK_TEST_FAST_PATH_MARKER"
    fi
    exit 0
  SHELL
  private_constant :FETCH_FAILING_STUB_GIT

  def per_commit_failing_stub_gh
    PER_COMMIT_FAILING_STUB_GH
  end

  def compare_failing_stub_gh
    COMPARE_FAILING_STUB_GH
  end

  def empty_compare_stub_gh
    EMPTY_COMPARE_STUB_GH
  end

  def fetch_failing_stub_git
    FETCH_FAILING_STUB_GIT
  end

  # End-to-end execution helper. Writes `stub_gh` and `stub_git` (the
  # marker-writing `git` stub unless a caller substitutes its own) into a temp
  # bin dir, prepends that bin dir to PATH, and runs the Decide block as a
  # stand-alone Bash script. The script is NOT prefixed with
  # `set -euo pipefail` — the brief does not enable
  # any shell options, and injecting them would mask a regression that
  # pipes the SHA stream into the loop (the inner pipeline's `exit 1`
  # would propagate via `pipefail`, hiding the fact that the subshell
  # exit only reached the subshell). Yields the captured (out, err,
  # status) tuple and the temp dir so callers can assert on stdout,
  # stderr, exit status, and the local-fast-path marker file inside
  # the same `Dir.mktmpdir` scope (the marker is auto-cleaned at block
  # end, so post-yield marker checks would see a deleted file).
  def run_decide_under_stubs(stub_gh, stub_git: STUB_GIT)
    decide_block = extract_decide_block
    skip 'no Decide block' if decide_block.empty?

    Dir.mktmpdir('wurk-brief-stub-') do |tmpdir|
      bin_dir = File.join(tmpdir, 'bin')
      Dir.mkdir(bin_dir)

      gh_path = File.join(bin_dir, 'gh')
      git_path = File.join(bin_dir, 'git')
      File.write(gh_path, stub_gh)
      File.write(git_path, stub_git)
      File.chmod(0o755, gh_path, git_path)

      script_path = File.join(tmpdir, 'decide.sh')
      File.write(script_path, "#!/usr/bin/env bash\n#{decide_block}\n")
      File.chmod(0o755, script_path)

      env = {
        'PATH' => "#{bin_dir}:#{ENV.fetch('PATH', '')}",
        'WURK_TEST_FAST_PATH_MARKER' => File.join(tmpdir, 'local_fast_path_reached')
      }

      result = Open3.capture3(env, script_path)
      yield(result, tmpdir)
    end
  end

  # Drives an abort-path test: the script must exit non-zero AND emit
  # the abort path's stderr diagnostic AND not reach the local fast
  # path's `git describe`. The diagnostic substring pin prevents an
  # unrelated early exit (a regression that drops the abort path
  # entirely, or one where a downstream step fails) from satisfying
  # `refute status.success?` — only the abort path prints this line.
  def assert_decide_aborts_before_local_fast_path(stub_gh:, failing_curl:, failure_message:, expected_stderr:,
                                                  stub_git: STUB_GIT)
    run_decide_under_stubs(stub_gh, stub_git: stub_git) do |(out, err, status), tmpdir|
      fast_path_marker = File.join(tmpdir, 'local_fast_path_reached')

      refute_predicate status, :success?,
                       "#{failure_message} (status=#{status.inspect}, " \
                       "failing_curl=#{failing_curl}); " \
                       "stdout=#{out.inspect}; stderr=#{err.inspect}"

      assert_includes err, expected_stderr,
                      "#{failure_message}: the abort path's expected stderr " \
                      "diagnostic `#{expected_stderr.inspect}` must be present " \
                      'so an unrelated early exit cannot satisfy this assertion; ' \
                      "got stderr=#{err.inspect}"

      refute fast_path_reached?(fast_path_marker),
             "#{failure_message} before the local fast path; " \
             'the stub `git describe` was reached, which means the script ran on ' \
             'past its abort — the failure was confined to a subshell or pipeline ' \
             'and its `exit 1` did not propagate to the Decide script'
    end
  end

  def fast_path_reached?(marker)
    File.exist?(marker) && File.read(marker).include?('LOCAL_FAST_PATH_REACHED')
  end

  def extract_decide_block
    return @extract_decide_block if defined?(@extract_decide_block)

    lines = @text.lines
    decide_idx = lines.index { |l| l.strip == '## Decide' }
    return @extract_decide_block = '' unless decide_idx

    open_idx = lines[decide_idx..].index { |l| l.start_with?('```bash') }
    return @extract_decide_block = '' unless open_idx

    abs_open = decide_idx + open_idx
    close_idx = lines[(abs_open + 1)..].index { |l| l.strip == '```' }
    return @extract_decide_block = '' unless close_idx

    abs_close = abs_open + 1 + close_idx
    @extract_decide_block = lines[(abs_open + 1)...abs_close].join
  end

  def parse_table_rows
    return @parse_table_rows if defined?(@parse_table_rows)

    lines = @text.lines
    header_idx = lines.index { |l| l.strip == '| Window | Do |' }
    @parse_table_rows =
      if header_idx
        rows = []
        lines.drop(header_idx + 1).each do |line|
          stripped = line.strip
          break if stripped.empty?

          match = ROW_RE.match(stripped)
          next unless match

          rows << {
            window: match[:window].strip,
            do: match[:do].strip,
            line: lines.index(line) + 1,
            raw: stripped
          }
        end
        rows
      else
        []
      end
  end

  def unknown_rows_in_table
    parse_table_rows.select { |row| row[:do].start_with?('unknown') }
  end

  def find_table_line_numbers
    parse_table_rows.map { |row| row[:line] }
  end

  def table_line?(line_no)
    find_table_line_numbers.include?(line_no)
  end

  def matching_refs_tags_block
    lines = @text.lines
    start_idx = lines.index { |l| l.include?('matching-refs/tags') }
    return nil unless start_idx

    # Collect the backslash-continued `last=$(gh api ...)` block up to
    # the `)` that closes the command substitution, so a later
    # `gh api .../git/ref/tags/$last` does not have its flags credited
    # to the matching-refs call.
    lines.drop(start_idx).take_while { |l| !l.rstrip.end_with?(')') }.join
  end
end
