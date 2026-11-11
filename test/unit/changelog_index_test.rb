# frozen_string_literal: true

require 'minitest/autorun'

# CHANGELOG.md is an index; each release's notes are docs/changelog/<version>.md
# and the next release's are docs/changelog/unreleased.md. The release lane
# reads both (bin/changelog-section, release:check), so a notes file with no
# index entry, or an entry with no file, is a release whose notes cannot be
# found from one side. Reads files and touches no Redis or shared state.
class ChangelogIndexTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  NOTES = File.join(ROOT, 'docs', 'changelog')
  ENTRY = /^## \[([^\]]+)\] - (\d{4}-\d{2}-\d{2})$/

  def index = @index ||= File.read(File.join(ROOT, 'CHANGELOG.md'))

  def entries = index.scan(ENTRY).to_h

  def notes_versions
    Dir[File.join(NOTES, '*.md')].map { |path| File.basename(path, '.md') } - ['unreleased']
  end

  def test_unreleased_notes_exist_and_carry_their_title
    path = File.join(NOTES, 'unreleased.md')

    assert_path_exists path, 'docs/changelog/unreleased.md is where the next release is written'
    assert_equal "# Unreleased\n", File.foreach(path).first
  end

  def test_every_notes_file_has_an_index_entry
    assert_empty notes_versions - entries.keys,
                 'these docs/changelog files have no `## [<version>] - <date>` entry in CHANGELOG.md'
  end

  def test_every_index_entry_has_a_notes_file
    assert_empty entries.keys - notes_versions,
                 'these CHANGELOG.md entries have no docs/changelog/<version>.md'
  end

  def test_each_notes_title_matches_its_index_entry
    entries.each do |version, date|
      title = File.foreach(File.join(NOTES, "#{version}.md")).first

      assert_equal "# #{version} — #{date}\n", title, "docs/changelog/#{version}.md title"
      assert_includes index, "](docs/changelog/#{version}.md)", "CHANGELOG.md must link #{version}'s notes"
    end
  end

  def test_index_is_newest_first
    versions = entries.keys.map { |v| Gem::Version.new(v) }

    assert_equal versions.sort.reverse, versions
  end

  def test_unreleased_compare_link_starts_at_the_newest_entry
    assert_match %r{^\[Unreleased\]: \S+/compare/v#{Regexp.escape(entries.keys.first)}\.\.\.HEAD$}, index
  end
end
