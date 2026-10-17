# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'open3'

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

  def test_gh_only_compare_call_is_piped_through_jq
    decide_block = extract_decide_block

    # The compare call must be piped through `jq` — an un-filtered
    # `gh api ... compare/$last...main` would not satisfy the row-1
    # "empty" verdict (the path filter would be missing) or row 5's
    # `<next>` cue (no per-commit date / subject to read).
    assert_match(
      %r{compare/[^"]+"\s*(?:\\?\n)?\s*\| jq},
      decide_block,
      'gh-only `gh api ... compare/$last...main` must be piped through ' \
      '`jq` to drive the path filter and emit commits'
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
      assert_includes out, "shipping #{pathspec}",
                      "commit touching ship-spec path `#{pathspec}` must be emitted"
      assert_includes out, 'a' * 7,
                      'commit short SHA (first 7 chars) must be emitted'
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
