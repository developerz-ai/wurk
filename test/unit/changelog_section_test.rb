# frozen_string_literal: true

require_relative '../test_helper'
require 'English'

# Drives the bin/changelog-section script against the real docs/changelog/
# notes so the release workflow's GitHub-Release-notes extraction is covered
# end to end.
class ChangelogSectionTest < Wurk::Test::UnitCase
  parallelize_me!

  SCRIPT = File.expand_path('../../bin/changelog-section', __dir__)

  # Array-form IO.popen, never backticks: a checkout path containing a space or
  # a shell metacharacter would otherwise be re-split (or executed) by the shell.
  # The block form is what sets $CHILD_STATUS.
  def test_prints_known_section_body
    out = IO.popen([SCRIPT, '0.0.5'], &:read)

    assert_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, 'Project logo'
    refute_includes out, '# 0.0.5', 'should print the body, not the title'
  end

  # The 0.0.1 body is the one the release notes extract for the first public
  # release; it was rewritten in place, so pin that it still prints, and that
  # it ends with its own notes: in the single-file CHANGELOG.md the last
  # section ran on into the compare links.
  def test_prints_the_first_release_section_body
    out = IO.popen([SCRIPT, '0.0.1'], &:read)

    assert_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, '### Dashboard'
    assert_includes out, '### Compat'
    refute_includes out, '# 0.0.1', 'should print the body, not the title'
    refute_includes out, '[Unreleased]:'
  end

  def test_fails_on_missing_version
    out = IO.popen([SCRIPT, '99.99.99'], err: %i[child out], &:read)

    refute_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, 'no docs/changelog/99.99.99.md'
  end

  # The argument becomes a path; anything but a version is refused, not read.
  def test_refuses_a_non_version_argument
    out = IO.popen([SCRIPT, '../../README'], err: %i[child out], &:read)

    refute_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, 'usage'
  end

  def test_requires_a_version_argument
    out = IO.popen([SCRIPT], err: %i[child out], &:read)

    refute_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, 'usage'
  end
end
