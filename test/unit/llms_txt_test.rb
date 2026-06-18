# frozen_string_literal: true

require_relative '../test_helper'

# Guards docs/site/llms.txt (the AI-agent map published at /wurk/llms.txt).
# Keeps it from silently drifting: it must follow the llms.txt format and every
# in-repo doc it links to must still exist. External (github.io / blob) links
# aren't fetched here — the repo-relative ones are the ones a rename can break.
class LlmsTxtTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  LLMS = File.join(ROOT, 'docs', 'site', 'llms.txt')

  def setup
    @text = File.read(LLMS)
  end

  def test_exists_and_follows_format
    assert File.file?(LLMS), 'docs/site/llms.txt must exist (published at /wurk/llms.txt)'
    assert_match(/\A# Wurk\n/, @text, 'must open with an H1 title')
    assert_match(/^> Wurk is a /, @text, 'must have a blockquote summary after the title')
    assert_match(/^## Docs$/, @text, 'must have a sectioned link list')
  end

  def test_states_the_core_migration_facts
    # The facts agents rely on — keep them present and correct.
    assert_includes @text, 'WURK_COUNT', 'must document the parallelism knob'
    assert_includes @text, 'no `WURK_CONCURRENCY` env var', 'must correct the WURK_CONCURRENCY misconception'
    assert_includes @text, 'WURK_DISABLED=1', 'must document the clustered-Puma fix'
  end

  def test_links_to_the_migration_guide_and_api_docs
    assert_includes @text, 'docs/migrate-from-sidekiq.md', 'must link the migration guide (#254)'
    assert_includes @text, 'developerz-ai.github.io/wurk/api/', 'must link the YARD API docs (#256)'
  end

  def test_repo_relative_doc_links_resolve
    # Every github.com/.../blob/main/<path> link must point at a real file.
    paths = @text.scan(%r{blob/main/([\w./-]+)}).flatten.uniq

    refute_empty paths, 'expected at least one in-repo doc link'
    missing = paths.reject { |rel| File.file?(File.join(ROOT, rel)) }

    assert_empty missing, "llms.txt links to missing repo files: #{missing.join(', ')}"
  end
end
