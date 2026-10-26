# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../tasks/llms_full'
require 'tmpdir'
require 'fileutils'

# Exercises the llms-full.txt generator (#255 optional deliverable). The file
# itself is build-time generated (gitignored, written by `rake docs:llms_full`
# in the pages workflow), so this tests the builder: added, renamed or removed
# top-level docs and dropped map sections cannot silently escape detection.
class LlmsFullTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)

  def setup
    @text = WurkDocs::LlmsFull.build(ROOT)
  end

  def test_starts_with_the_map_h1_and_summary
    assert_match(/\A# Wurk\n/, @text, 'llms-full must lead with the H1 (llms.txt map first)')
    assert_match(/^> Wurk is a /, @text, 'must carry the blockquote summary')
    assert_includes @text, '# Full documents', 'must separate the inlined full guides'
  end

  def test_every_top_level_doc_is_accounted_for_and_selected_bodies_are_verbatim
    discovered = Dir.glob('docs/*.md', base: ROOT)
    included = WurkDocs::LlmsFull::DOCS
    excluded = WurkDocs::LlmsFull::EXCLUSIONS

    assert_equal discovered.sort, (included + excluded.keys).sort
    assert_empty included & excluded.keys
    assert_equal included.uniq, included
    excluded.each_value { |reason| refute_empty reason.strip }

    (discovered - excluded.keys).each do |rel|
      assert_includes @text, "<!-- source: #{rel} -->\n\n#{File.read(File.join(ROOT, rel))}",
                      "#{rel} body not inlined verbatim in llms-full"
    end
  end

  def test_secrets_is_inlined_and_scope_specific_exclusions_are_not
    assert_includes @text, "<!-- source: docs/secrets.md -->\n\n#{File.read(File.join(ROOT, 'docs/secrets.md'))}"
    assert_equal %w[docs/compatibility.md docs/conformance.md docs/demo-deploy.md],
                 WurkDocs::LlmsFull::EXCLUSIONS.keys.sort
    WurkDocs::LlmsFull::EXCLUSIONS.each_key do |rel|
      refute_includes @text, "<!-- source: #{rel} -->"
    end
  end

  def test_unknown_guide_fails_build_with_its_path
    with_fixture_root do |root|
      File.write(File.join(root, 'docs/new-guide.md'), '# New guide')
      error = assert_raises(ArgumentError) { WurkDocs::LlmsFull.build(root) }
      assert_includes error.message, 'unaccounted docs'
      assert_includes error.message, 'docs/new-guide.md'
    end
  end

  def test_accounted_exclusions_pass_without_inlining_their_bodies
    with_fixture_root do |root|
      text = WurkDocs::LlmsFull.build(root)

      WurkDocs::LlmsFull::EXCLUSIONS.each_key do |rel|
        refute_includes text, File.read(File.join(root, rel))
      end
      assert_includes text, File.read(File.join(root, 'docs/secrets.md'))
    end
  end

  def test_missing_included_and_excluded_files_fail_build
    %w[docs/secrets.md docs/conformance.md].each do |rel|
      with_fixture_root do |root|
        File.delete(File.join(root, rel))
        error = assert_raises(ArgumentError) { WurkDocs::LlmsFull.build(root) }
        assert_includes error.message, 'missing/stale inventory entries'
        assert_includes error.message, rel
      end
    end
  end

  def test_invalid_inventory_entries_have_actionable_diagnostics
    with_fixture_root do |root|
      docs = WurkDocs::LlmsFull::DOCS
      exclusions = WurkDocs::LlmsFull::EXCLUSIONS
      cases = [
        [docs + ['docs/stale.md'], exclusions, 'missing/stale inventory entries', 'docs/stale.md'],
        [docs, exclusions.merge('docs/stale.md' => 'Removed'), 'missing/stale inventory entries', 'docs/stale.md'],
        [docs, exclusions.merge('docs/conformance.md' => " \n"), 'blank exclusion reasons', 'docs/conformance.md'],
        [docs, exclusions.merge('docs/secrets.md' => 'Overlap'), 'included and excluded', 'docs/secrets.md'],
        [docs + ['docs/secrets.md'], exclusions, 'duplicate inclusions', 'docs/secrets.md']
      ]
      cases.each do |included, excluded, diagnostic, path|
        error = assert_raises(ArgumentError) do
          WurkDocs::LlmsFull.validate_inventory(root, docs: included, exclusions: excluded)
        end
        assert_includes error.message, diagnostic
        assert_includes error.message, path
      end
    end
  end

  def test_inlines_real_guide_content
    # Anchor on distinctive strings so an empty/placeholder doc is caught.
    assert_includes @text, 'Concurrency vs parallelism', 'migration-guide body missing'
    assert_includes @text, 'queue_adapter = :wurk', 'active-job guide body missing'
  end

  def test_map_source_is_present
    assert_path_exists File.join(ROOT, WurkDocs::LlmsFull::MAP)
    assert @text.start_with?(File.read(File.join(ROOT, WurkDocs::LlmsFull::MAP)).rstrip)
  end

  private

  def with_fixture_root
    Dir.mktmpdir('llms-full-test') do |root|
      FileUtils.mkdir_p(File.join(root, 'docs/site'))
      File.write(File.join(root, WurkDocs::LlmsFull::MAP), '# Fixture map')
      Dir.glob('docs/*.md', base: ROOT).each do |rel|
        File.write(File.join(root, rel), "# Unique fixture body for #{rel}\n\n")
      end
      yield root
    end
  end
end
