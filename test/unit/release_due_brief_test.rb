# frozen_string_literal: true

require 'minitest/autorun'

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

  def test_jq_filter_restricts_files_to_seven_ship_spec_paths
    decide_block = extract_decide_block

    # The jq filter must select `.files[].filename`.
    assert_match(/\.files\b/, decide_block,
                 'the jq filter must reference `.files[]`')

    assert_match(/\bfilename\b/, decide_block,
                 'the jq filter must extract `.filename` from each .files[] entry')

    # The jq filter must restrict to all seven ship-spec paths. Each
    # pathspec must appear in jq-regex form (e.g. `lib/.*\.rb`) inside
    # the filter — the pathspec form (`lib/**/*.rb`) used in the local
    # fast path is not a substitute, since git pathspecs and jq regex
    # are different DSLs.
    needles = {
      'lib/**/*.rb' => 'lib/.*\.rb',
      'lib/**/*.lua' => 'lib/.*\.lua',
      'app/**/*.rb' => 'app/.*\.rb',
      'config/**' => 'config(/.*)?',
      'exe/*' => 'exe/[^/]+',
      'frontend/src/**' => 'frontend/src(/.*)?',
      'wurk.gemspec' => 'wurk\.gemspec'
    }

    needles.each do |pathspec, jq_form|
      assert_match(/#{Regexp.escape(jq_form)}/, decide_block,
                   'the jq filter must restrict to the ship-spec path ' \
                   "`#{pathspec}` (in jq-regex form: `#{jq_form}`)")
    end
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
