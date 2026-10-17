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
      failure_message: 'per-commit `gh api commits/<sha>` failure must abort the Decide script'
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
      failure_message: 'Compare request failure must abort the Decide script'
    )
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

  def per_commit_failing_stub_gh
    PER_COMMIT_FAILING_STUB_GH
  end

  def compare_failing_stub_gh
    COMPARE_FAILING_STUB_GH
  end

  # Write `stub_gh` and a marker-writing `git` stub into a temp bin dir,
  # prepend that bin dir to PATH, and run the Decide block as a
  # stand-alone Bash script with `set -euo pipefail`. The marker is
  # empty unless the script reaches the local fast path's `git describe`
  # (the first git command after the per-commit loop). A regression that
  # lets a per-commit or Compare failure fall through to the local fast
  # path would write the marker; a regression that runs the while loop
  # in a subshell (e.g. piping the SHA stream into `read`) would let
  # `exit 1` exit only the subshell and the marker would still be
  # written. The two assertions together pin that the abort propagates
  # to the Decide script AND that it propagates BEFORE the local fast
  # path runs.
  def assert_decide_aborts_before_local_fast_path(stub_gh:, failing_curl:, failure_message:)
    decide_block = extract_decide_block
    skip 'no Decide block' if decide_block.empty?

    Dir.mktmpdir('wurk-brief-stub-') do |tmpdir|
      bin_dir = File.join(tmpdir, 'bin')
      Dir.mkdir(bin_dir)
      fast_path_marker = File.join(tmpdir, 'local_fast_path_reached')

      gh_path = File.join(bin_dir, 'gh')
      git_path = File.join(bin_dir, 'git')
      File.write(gh_path, stub_gh)
      File.write(git_path, STUB_GIT)
      File.chmod(0o755, gh_path, git_path)

      script_path = File.join(tmpdir, 'decide.sh')
      File.write(script_path, "#!/usr/bin/env bash\nset -euo pipefail\n#{decide_block}\n")
      File.chmod(0o755, script_path)

      env = {
        'PATH' => "#{bin_dir}:#{ENV.fetch('PATH', '')}",
        'WURK_TEST_FAST_PATH_MARKER' => fast_path_marker
      }
      out, err, status = Open3.capture3(env, script_path)

      refute_predicate status, :success?,
                       "#{failure_message} (status=#{status.inspect}, " \
                       "failing_curl=#{failing_curl}); " \
                       "stdout=#{out.inspect}; stderr=#{err.inspect}"

      refute fast_path_reached?(fast_path_marker),
             "#{failure_message} before the local fast path; " \
             'the stub `git describe` was reached, which means the ' \
             'while loop ran in a subshell and its `exit 1` did not ' \
             'propagate to the Decide script'
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
end
