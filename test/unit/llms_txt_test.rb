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

  # Variants used by the docs today: "in CI", "in the `ecosystem` CI job",
  # "on every push". Each one means "this gem's upstream suite runs on every
  # PR"; anything in that phrasing has to point at a harness on disk.
  CI_CLAIM = /\b(?:in CI|in the `ecosystem` CI job|on every push)\b/

  def test_every_sidekiq_gem_claimed_to_run_in_ci_has_a_pin
    # llms.txt is the map agents consume. If it claims a sidekiq-* gem runs
    # in CI, the claim has to be backed by a harness on disk
    # (test/ecosystem/<gem>/PIN) — otherwise the doc is making a promise
    # CI doesn't keep. Target additions phrase themselves as "target
    # addition" or "tracked in docs/idea/14-ecosystem-compat.md" and do not
    # trigger this regex.
    claimed = @text.lines.grep(CI_CLAIM)
                   .flat_map { |line| line.scan(/sidekiq-[\w-]+/) }.uniq

    missing = claimed.reject { |gem| File.file?(File.join(ROOT, 'test', 'ecosystem', gem, 'PIN')) }

    assert_empty missing,
                 'docs/site/llms.txt claims these run in CI but no test/ecosystem/<gem>/PIN ' \
                 "exists on disk: #{missing.join(', ')}"
  end
end
