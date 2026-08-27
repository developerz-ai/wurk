# frozen_string_literal: true

require_relative '../test_helper'
require 'English'

# Drives the bin/release-notes script against the real CHANGELOG.md and git
# history so the release workflow's generated GitHub-Release notes are covered
# end to end. WURK_PREV_TAG pins the commit range to a fixed old commit so the
# assertions are deterministic without relying on any tag.
class ReleaseNotesTest < Wurk::Test::UnitCase
  parallelize_me!

  SCRIPT = File.expand_path('../../bin/release-notes', __dir__)

  # feat(api) slice 07b (#407); the range after it holds 2 feat, 9 fix, 1 perf
  # and 13 non-conventional subjects. Verified against `git log` on main.
  PREV_TAG = 'c8af52473c5d72a0452b838cd4383e188ab2a7c1'

  # Array-form IO.popen, never backticks: a checkout path containing a space or
  # a shell metacharacter would otherwise be re-split (or executed) by the shell.
  # The block form is what sets $CHILD_STATUS.
  def run(*args, prev_tag: PREV_TAG)
    env = prev_tag ? { 'WURK_PREV_TAG' => prev_tag } : {}
    IO.popen([env, SCRIPT, *args].reject(&:empty?), err: %i[child out], &:read)
  end

  # ---- Happy path: pinned range ---

  def test_prints_changelog_section_body
    out = run('1.7.3')

    assert_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, '## Changelog'
    assert_includes out, '### Fixed'
    refute_includes out, '## [1.7.3]', 'should print the section body, not its header'
    refute_includes out, '## [1.7.2]', 'must stop at the next version header'
  end

  def test_prints_commits_since_heading_with_prev_tag
    out = run('1.7.3')

    assert_includes out, "## Commits since #{PREV_TAG}"
  end

  def test_groups_conventional_subjects_by_type
    out = run('1.7.3')

    assert_includes out, '### Features'
    assert_includes out, '- DAG builder, atomic creation, sibling-safe completion, chains (slice 11) (#411)'
    assert_includes out, '### Bug Fixes'
    assert_includes out, '- stop `bundle exec wurk` running two workers in a Rails app (#437)'
    assert_includes out, '### Performance'
    assert_includes out, '- cheaper per-job and boot paths, cheap CI, slimmer Sidekiq framing (#415)'
  end

  def test_lists_unknown_types_under_other
    out = run('1.7.3')

    assert_includes out, '### Other'
    # "ci: finish ..." is conventional but not feat/fix/perf: it lands in
    # Other, printed as the summary without the "ci: " prefix.
    assert_includes out, '- finish an existing release instead of failing after gem push (#440)'
    # So does "docs: ..." — a scope-less type still matches the format.
    assert_includes out, '- fix three docs still claiming CI runs on Blacksmith (#443)'
  end

  def test_places_commits_before_the_changelog
    out = run('1.7.3')

    assert out.index('## Changelog') < out.index('## Commits since'),
           'the Changelog section must come first'
  end

  def test_prev_tag_argument_overrides_env
    # An unknown ref makes the script reject the tag, proving the argument
    # (not the env) supplied the range.
    out = run('1.7.3', 'no-such-ref-0000000', prev_tag: nil)

    refute_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, 'unknown prev-tag'
  end

  # ---- Errors ---

  def test_requires_a_version_argument
    out = run

    refute_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, 'usage'
  end

  def test_fails_on_missing_changelog_section
    out = run('99.99.99')

    refute_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, 'no `## [99.99.99]`'
  end

  # ---- Zero matches must still exit 0 ---

  def test_exits_zero_when_the_range_has_no_commits
    # HEAD..HEAD is empty: no conventional commits to group, yet the Changelog
    # section still prints and the run stays green — a release must never go
    # red over commit-message style.
    out = run('1.7.3', prev_tag: 'HEAD')

    assert_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, '## Changelog'
    assert_includes out, '## Commits since HEAD'
    assert_includes out, 'No commits found'
  end
end
