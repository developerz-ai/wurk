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
  # The `\[?` allows the job name to appear as a markdown link
  # ("in the [`ecosystem` CI job](...)"), the form README.md:300 uses.
  CI_CLAIM = /\b(?:in CI|in the \[?`ecosystem` CI job|on every push)\b/

  def test_every_sidekiq_gem_claimed_to_run_in_ci_has_a_pin
    # llms.txt is the map agents consume. If it claims a sidekiq-* gem runs
    # in CI, the claim has to be backed by a harness on disk
    # (test/ecosystem/<gem>/PIN) — otherwise the doc is making a promise
    # CI doesn't keep. Target additions phrase themselves as "target
    # addition" or "tracked in docs/idea/14-ecosystem-compat.md" and do not
    # trigger this regex. Only gems that appear up to the end of the
    # CI_CLAIM match are considered, matching readme_claims_test.rb and
    # claude_md_claims_test.rb; a tracked list that follows the claim on the
    # same line ("sidekiq-cron runs in CI; sidekiq-foo is tracked in ...") is
    # not itself a CI claim.
    claimed = @text.lines.flat_map do |line|
      match = CI_CLAIM.match(line)
      next [] unless match

      line[0...match.end(0)].scan(/sidekiq-[\w-]+/)
    end.uniq

    missing = claimed.reject { |gem| File.file?(File.join(ROOT, 'test', 'ecosystem', gem, 'PIN')) }

    assert_empty missing,
                 'docs/site/llms.txt claims these run in CI but no test/ecosystem/<gem>/PIN ' \
                 "exists on disk: #{missing.join(', ')}"
  end

  # The single-fetch pitch (the blockquote pointing at llms-full.txt). The full
  # dump inlines the top-level docs/*.md guides only — tasks/llms_full.rb keeps
  # the docs/target/sidekiq-*.md parity specs and other reference material as
  # map links by design — so the pitch must scope its "inlined" promise the
  # same way and must not promise every guide.
  FULL_LINK = '[llms-full.txt](https://developerz-ai.github.io/wurk/llms-full.txt)'
  EVERY_GUIDE_INLINED = /every (?:guide|document|doc)\b[^.]*\binlined/i

  def test_single_fetch_pitch_scopes_what_llms_full_inlines
    line = @text.lines.find { |l| l.include?('llms-full.txt') }

    refute_nil line, 'must have a single-fetch pitch naming llms-full.txt'
    assert_includes line, FULL_LINK, 'must keep the llms-full.txt markdown link byte-identical'
    assert_match(/inlined/, line, 'must say what llms-full inlines')
    assert_match(%r{top-level docs/ guides}, line, 'must scope the inlined text to the top-level docs/ guides')
    assert_match(/specs?\b/, line, 'must name the parity specs')
    assert_match(%r{docs/target}, line, 'must point the linked-only specs at docs/target')
    assert_match(/linked/, line, 'must say what stays linked-only')
    refute_match(EVERY_GUIDE_INLINED, line,
                 'must not promise the full text of every guide below inlined — llms-full carries the ' \
                 'top-level docs/ guides; the parity specs and other reference material stay linked')
  end
end
