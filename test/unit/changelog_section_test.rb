# frozen_string_literal: true

require_relative '../test_helper'
require 'English'

# Drives the bin/changelog-section script against the real CHANGELOG.md so the
# release workflow's GitHub-Release-notes extraction is covered end to end.
class ChangelogSectionTest < Wurk::Test::UnitCase
  parallelize_me!

  SCRIPT = File.expand_path('../../bin/changelog-section', __dir__)

  def test_prints_known_section_body # rubocop:disable Minitest/MultipleAssertions
    out = `#{SCRIPT} 0.0.5`

    assert_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, 'Project logo'
    refute_includes out, '## [0.0.5]', 'should print the body, not the header'
    refute_includes out, '## [0.0.4]', 'must stop at the next version header'
  end

  def test_fails_on_missing_version
    out = `#{SCRIPT} 99.99.99 2>&1`

    refute_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, 'no `## [99.99.99]`'
  end

  def test_requires_a_version_argument
    out = `#{SCRIPT} 2>&1`

    refute_equal 0, $CHILD_STATUS.exitstatus
    assert_includes out, 'usage'
  end
end
