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

    assert block.include?('--paginate'),
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
