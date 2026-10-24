# frozen_string_literal: true

require 'minitest/autorun'

# Pins RELEASE.md's `### Release states` table: the classification of a
# GitHub Release for a `vX.Y.Z` tag, and the permission to recover from it.
#
# The two questions used to be answered by one fuzzy rule ("author=bot means
# gem-less"), which got a real release classified as defective: a
# `developerz-ai[bot]`-authored Release that carries the `.gem` is a
# SANCTIONED MANUAL release, not a defect, and the author is never the
# trigger. The asset count is. The table also separates classification from
# permission: the delete runbook may only ever be named for the zero-asset
# case, and a tag with no Release at all is UNCLASSIFIED until the RubyGems
# probe and the last release.yml run corroborate which of three possibilities
# it is.
#
# Reads one file; touches no Redis or shared state.
class ReleaseStatesDocTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  RELEASE_MD = File.join(ROOT, 'RELEASE.md')

  def setup
    @section = release_states_section
    @rows = table_rows(@section)
  end

  def test_release_states_section_exists
    refute_nil @section,
               'RELEASE.md must keep a `### Release states` section — the release ' \
               'state classification lives there'
  end

  def test_release_states_table_has_a_row_per_state
    refute_empty @rows,
                 'RELEASE.md\'s `### Release states` section must carry a table ' \
                 'with one row per release state'

    assert_equal 4, @rows.size,
                 'the release-state table must classify exactly four states (a CI ' \
                 'Release with the .gem, a zero-asset Release, a sanctioned manual ' \
                 'Release with the .gem, and no Release for the tag); got ' \
                 "#{@rows.size} rows: #{@rows.map { |r| r[:state] }.inspect}"
  end

  # The CI case: `github-actions[bot]` with the `.gem` attached. A real
  # release, nothing to recover.
  def test_ci_release_with_the_gem_is_classified_as_published
    row = row_matching(/github-actions\[bot\]/)

    refute_nil row,
               'the release-state table must keep the CI-published case: a ' \
               'Release authored by `github-actions[bot]` with the `.gem` attached'

    assert_match(/CI-published/i, row[:what],
                 'the CI row must classify the state as a CI-published release')
    assert_match(/none/i, row[:recovery],
                 "the CI row's recovery cell must say no recovery is due; got " \
                 "#{row[:recovery].inspect}")
  end

  # The stray case: a Release with ZERO assets, whatever its author. This is
  # the ONLY state the delete runbook may touch.
  def test_zero_asset_release_is_the_gem_less_stray_case
    row = row_matching(/zero assets/i)

    refute_nil row,
               'the release-state table must keep the stray case: a Release with ' \
               'zero assets, from any author'

    assert_match(/gem-less/i, row[:what],
                 'the zero-asset row must classify the state as a gem-less release')
    assert_match(/runbook/i, row[:recovery],
                 "the zero-asset row's recovery cell must name the gem-less " \
                 "runbook; got #{row[:recovery].inspect}")
  end

  # The sanctioned manual case: `developerz-ai[bot]` (or a human) WITH the
  # `.gem` attached. A real release — never deleted, and never called a
  # defect because of its author.
  def test_bot_authored_release_carrying_the_gem_is_a_sanctioned_manual_release
    row = row_matching(/developerz-ai\[bot\]/)

    refute_nil row,
               'the release-state table must keep the manual case: a Release ' \
               'authored by `developerz-ai[bot]` (or a human) that carries the ' \
               '`.gem`'

    assert_match(/\.gem/, row[:state],
                 'the manual row must be the case where the `.gem` IS attached')
    assert_match(/sanctioned manual|break-glass/i, row[:what],
                 'the manual row must classify the state as a sanctioned manual ' \
                 "/break-glass release; got #{row[:what].inspect}")
    assert_match(/never delete|not the defect|real release/i, row[:recovery],
                 "the manual row's recovery cell must say the release is never " \
                 'deleted and its author is not the defect; got ' \
                 "#{row[:recovery].inspect}")

    refute_match(/defect|gem-less/i, row[:what],
                 'a `developerz-ai[bot]`-authored Release that carries the `.gem` ' \
                 "must not be labelled a defect; got #{row[:what].inspect}")
  end

  # The unclassified case: no Release for the tag. Three possibilities, and
  # none of them may be decided without corroborating evidence.
  def test_no_release_case_names_all_three_possibilities
    row = row_matching(/no release/i)

    refute_nil row,
               'the release-state table must keep the case where no Release ' \
               'exists for the tag'

    what = row[:what]

    assert_match(/preflight/i, what,
                 'the no-Release row must name the `release.yml` preflight ' \
                 "no-op as one possibility; got #{what.inspect}")
    assert_match(/break-glass|manual/i, what,
                 'the no-Release row must name a break-glass publication as one ' \
                 "possibility; got #{what.inspect}")
    assert_match(/failure/i, what,
                 'the no-Release row must name a failure before the Release was ' \
                 "created as one possibility; got #{what.inspect}")
    assert_match(/unclassified/i, what,
                 'the no-Release row must classify the state as unclassified; got ' \
                 "#{what.inspect}")
  end

  def test_no_release_case_requires_corroborating_evidence_before_recovering
    row = row_matching(/no release/i)

    refute_nil row,
               'the release-state table must keep the case where no Release ' \
               'exists for the tag'

    recovery = row[:recovery]

    assert_match(/rubygems/i, recovery,
                 'the no-Release row must require the RubyGems probe as ' \
                 "corroborating evidence; got #{recovery.inspect}")
    assert_match(/release\.yml/i, recovery,
                 'the no-Release row must require the last `release.yml` run as ' \
                 "corroborating evidence; got #{recovery.inspect}")
    assert_match(/none until|corroborat/i, recovery,
                 'the no-Release row must permit no recovery until the state is ' \
                 "corroborated; got #{recovery.inspect}")
  end

  # Classification and permission are separate columns, and the runbook is
  # named ONLY for the zero-asset case. A row that reaches the deletion
  # runbook from any other state is a defect: it would let a real release be
  # deleted.
  def test_delete_runbook_is_named_only_for_the_zero_asset_case
    zero_asset = row_matching(/zero assets/i)

    refute_nil zero_asset,
               'the release-state table must keep the zero-asset row'

    runbook_rows = @rows.select { |row| row[:recovery].match?(/runbook/i) }

    assert_equal [zero_asset[:state]], runbook_rows.map { |row| row[:state] },
                 'only the zero-asset row may name the deletion runbook; got ' \
                 "#{runbook_rows.map { |row| row[:state] }.inspect}"
  end

  # The zero-asset row is the only one the runbook may touch, and even there
  # the probe must confirm NON-publication first: release.yml pushes the gem
  # before it creates the Release and uploads the asset, so a succeeded push
  # with a failed upload leaves zero assets on a version RubyGems has
  # already burned — deleting on the asset count alone would strip a real
  # release's tag and Latest pointer (review thread PRRT_kwDOSi_O686v4LZ6).
  def test_zero_asset_recovery_is_gated_behind_probe_confirmed_non_publication
    row = row_matching(/zero assets/i)

    refute_nil row, 'the release-state table must keep the zero-asset row'

    recovery = row[:recovery]

    assert_match(/rubygems\s+probe/i, recovery,
                 "the zero-asset row's recovery cell must require the RubyGems probe; got " \
                 "#{recovery.inspect}")
    assert_match(/only after|before/i, recovery,
                 "the zero-asset row's recovery cell must sequence the probe BEFORE the " \
                 "runbook, not alongside it; got #{recovery.inspect}")
    assert_match(/no gem was published|never published|non-publication/i, recovery,
                 "the zero-asset row's recovery cell must require the probe to confirm " \
                 'non-publication — zero assets alone is also the shape of a succeeded gem ' \
                 "push whose asset upload failed; got #{recovery.inspect}")
  end

  # Neither the author nor the absence of a Release establishes publication.
  # RubyGems is the authority.
  def test_section_states_that_neither_author_nor_absence_establishes_publication
    assert_match(/author/i, @section,
                 'the release-state section must say the author does not ' \
                 'establish publication')
    assert_match(/absence of a release/i, @section,
                 'the release-state section must say the absence of a Release ' \
                 'does not establish publication')
    assert_match(/rubygems/i, @section,
                 'the release-state section must name RubyGems as the authority')
  end

  private

  # The RELEASE.md block between the `### Release states` heading and the next
  # heading of any level.
  def release_states_section
    lines = File.readlines(RELEASE_MD)
    first = lines.index { |l| l.start_with?('### Release states') }
    return nil unless first

    last = ((first + 1)...lines.size).find { |i| lines[i].start_with?('#') } || lines.size
    lines[first...last].join
  end

  # The table's data rows, each split into its three cells: state, what it is,
  # destructive recovery. The header and its `|---|` separator are skipped.
  def table_rows(section)
    return [] if section.nil?

    section.lines.filter_map do |line|
      stripped = line.strip
      next unless stripped.start_with?('|')
      next if stripped.match?(/\A\|[\s|:-]+\|\z/)

      cells = stripped.split('|', -1).map(&:strip).reject(&:empty?)
      next unless cells.length >= 3
      # The header row is prose in the first cell, not a state.
      next if cells[0].casecmp?('State')

      { state: cells[0], what: cells[1], recovery: cells[2] }
    end
  end

  def row_matching(pattern)
    @rows.find { |row| row[:state].match?(pattern) }
  end
end
