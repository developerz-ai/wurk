# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

# Ensures authoritative spec docs (the oracles for wire-compat) are present
# and non-empty. These files are critical to parity testing and must never be
# deleted or truncated; they live under docs/target/ at repo root.
#
# The SET of spec docs is defined once, in docs/target/SPEC_FILES - the same
# manifest the CI `spec-docs` job reads. This guard therefore asserts three
# things: the manifest exists and yields at least one entry, every doc it
# lists exists and is non-empty, and the manifest's set equals the
# docs/target/*.md files on disk (so a spec doc added to, or removed from, the
# directory without a matching manifest edit fails here). A fourth case pins
# the manifest FORMAT the CI reader honours too: entries are trimmed, and
# comment and blank lines are skipped.
#
# Background: during audit, spec files were found deleted but uncommitted,
# breaking parity-test validation. This guard prevents silent regressions.
#
# Reads files only: no test_helper, no Redis, no parallel fork, so it stays
# runnable on its own (`bin/rake test:unit TEST=test/unit/spec_docs_test.rb`).
class SpecDocsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DOCS_TARGET = File.join(ROOT, 'docs', 'target')
  MANIFEST = File.join(DOCS_TARGET, 'SPEC_FILES')

  def test_the_manifest_exists_and_lists_at_least_one_spec_doc
    assert_path_exists MANIFEST, "the spec-file manifest #{MANIFEST} does not exist"

    refute_empty manifest_files, "#{MANIFEST} lists no spec docs"
  end

  def test_every_listed_spec_doc_exists_and_is_nonempty
    assert_path_exists MANIFEST, "the spec-file manifest #{MANIFEST} does not exist"

    manifest_files.each do |filename|
      spec_file = File.join(DOCS_TARGET, filename)

      assert_path_exists spec_file, "spec doc #{filename} does not exist in docs/target/"
      assert_operator File.size(spec_file), :>, 0, "spec doc #{filename} is empty (0 bytes)"
    end
  end

  def test_the_manifest_lists_exactly_the_spec_docs_on_disk
    assert_path_exists MANIFEST, "the spec-file manifest #{MANIFEST} does not exist"

    on_disk = Dir[File.join(DOCS_TARGET, '*.md')].map { |path| File.basename(path) }.sort

    assert_equal on_disk, manifest_files.sort,
                 'docs/target/SPEC_FILES and the docs/target/*.md files on disk must be the same set'
  end

  # The manifest format promises "strip surrounding whitespace from each line"
  # (docs/target/SPEC_FILES). Without this case, dropping the trim or the
  # blank-line skip would leave every other test green.
  def test_the_manifest_parser_trims_entries_and_skips_comments_and_blank_lines
    Dir.mktmpdir('wurk-spec-docs-manifest-') do |dir|
      manifest = File.join(dir, 'SPEC_FILES')
      File.write(manifest, "# a comment\n\n  sidekiq-free.md  \n")

      assert_equal ['sidekiq-free.md'], manifest_files(manifest)
    end
  end

  private

  # The manifest format, shared with the CI job: one filename per line,
  # relative to docs/target/; surrounding whitespace is stripped, and blank
  # lines and '#' comments are skipped.
  def manifest_files(path = MANIFEST)
    File.readlines(path).filter_map do |line|
      entry = line.strip
      next if entry.empty? || entry.start_with?('#')

      entry
    end
  end
end
