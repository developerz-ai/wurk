# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../tasks/llms_full'

# Exercises the llms-full.txt generator (#255 optional deliverable). The file
# itself is build-time generated (gitignored, written by `rake docs:llms_full`
# in the pages workflow), so this tests the builder: a renamed/removed source
# doc, or a dropped map section, fails CI instead of silently shrinking the dump.
class LlmsFullTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @text = WurkDocs::LlmsFull.build(ROOT)
  end

  def test_starts_with_the_map_h1_and_summary
    assert_match(/\A# Wurk\n/, @text, 'llms-full must lead with the H1 (llms.txt map first)')
    assert_match(/^> Wurk is a /, @text, 'must carry the blockquote summary')
    assert_includes @text, '# Full documents', 'must separate the inlined full guides'
  end

  def test_every_source_doc_exists_and_is_inlined
    WurkDocs::LlmsFull::DOCS.each do |rel|
      assert_path_exists File.join(ROOT, rel), "generator references a missing doc: #{rel}"
      assert_includes @text, "<!-- source: #{rel} -->", "#{rel} not inlined in llms-full"
    end
  end

  def test_inlines_real_guide_content
    # Anchor on distinctive strings so an empty/placeholder doc is caught.
    assert_includes @text, 'Concurrency vs parallelism', 'migration-guide body missing'
    assert_includes @text, 'queue_adapter = :wurk', 'active-job guide body missing'
  end

  def test_map_source_is_present
    assert_path_exists File.join(ROOT, WurkDocs::LlmsFull::MAP)
  end
end
