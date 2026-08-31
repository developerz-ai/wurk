# frozen_string_literal: true

require 'minitest/autorun'

# The gate on docs/wiki/, which .github/workflows/publish-wiki.yml force-mirrors
# onto the public GitHub wiki on every merge to main.
#
# The wiki repo has no pull requests and no CI of its own, so before docs/wiki/
# existed nothing checked a wiki edit at all: "Free forever. Faster." shipped on
# the front page and survived there for the wiki's entire life, contradicting
# both docs/benchmarks.md and the project's own rule against the claim. Moving
# the source in-repo only helps if something reads it — that is this file.
class WikiPagesTest < Minitest::Test
  # Reads files and touches no Redis or shared state.
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  WIKI = File.join(ROOT, 'docs', 'wiki')

  # Orientation pages, not reference docs: past ~70 lines a page is copying
  # docs/<topic>.md instead of linking it, and duplicated prose is the drift
  # this whole gate exists to prevent.
  MAX_LINES = 70

  # Wurk is 0.87x-1.02x against stock Sidekiq (docs/benchmarks.md). There is no
  # "but this instance is fine" case: if the numbers ever change, they change in
  # docs/benchmarks.md first and this guard is updated deliberately.
  FORBIDDEN_CLAIM = /faster/i

  # Deep links point at the reference docs on main by absolute URL, because a
  # relative path does not resolve from the wiki (a separate repo). The path
  # after blob/main/ is still a real path in THIS repo, so it is checkable here
  # — which is the point: a renamed doc breaks the build, not the public wiki.
  BLOB_LINK = %r{https://github\.com/developerz-ai/wurk/blob/main/([^)\s#]+)}
  RELATIVE_DOCS_LINK = %r{\]\((docs/[^)\s#]+)\)}
  WIKI_LINK = /\[\[([^\]|]+)(?:\|[^\]]*)?\]\]/

  def pages
    @pages ||= Dir.children(WIKI).select { |f| f.end_with?('.md') }.sort
  end

  def test_wiki_source_directory_is_populated
    assert_path_exists WIKI, 'docs/wiki/ is the source of truth for the public wiki'
    refute_empty pages, 'docs/wiki/ must contain the wiki pages'
  end

  def test_no_page_claims_wurk_is_faster
    offenders = pages.flat_map do |page|
      File.readlines(File.join(WIKI, page)).each_with_index.filter_map do |line, i|
        "#{page}:#{i + 1}: #{line.strip}" if line.match?(FORBIDDEN_CLAIM)
      end
    end

    assert_empty offenders,
                 'Wurk is 0.87x-1.02x against stock Sidekiq, so the wiki must not say "faster" ' \
                 "(see docs/benchmarks.md):\n#{offenders.join("\n")}"
  end

  def test_every_docs_deep_link_resolves_to_a_file_in_this_repo
    broken = pages.flat_map do |page|
      body = File.read(File.join(WIKI, page))
      targets = body.scan(BLOB_LINK).flatten + body.scan(RELATIVE_DOCS_LINK).flatten
      targets.reject { |t| File.exist?(File.join(ROOT, t)) }.map { |t| "#{page} -> #{t}" }
    end

    assert_empty broken,
                 "wiki deep links must resolve to a file on main:\n#{broken.join("\n")}"
  end

  def test_every_wiki_link_resolves_to_a_page
    known = pages.map { |p| p.delete_suffix('.md') }

    broken = pages.flat_map do |page|
      File.read(File.join(WIKI, page)).scan(WIKI_LINK).flatten.filter_map do |target|
        # GitHub resolves [[Some Page]] to the file Some-Page.md.
        "#{page} -> [[#{target}]]" unless known.include?(target.strip.tr(' ', '-'))
      end
    end

    assert_empty broken,
                 "[[wiki links]] must name a page in docs/wiki/:\n#{broken.join("\n")}"
  end

  def test_pages_stay_orientation_sized
    oversized = pages.filter_map do |page|
      lines = File.foreach(File.join(WIKI, page)).count
      "#{page} (#{lines} lines)" if lines > MAX_LINES
    end

    assert_empty oversized,
                 'wiki pages are orientation, not reference — link docs/<topic>.md instead of ' \
                 "copying it (max #{MAX_LINES} lines):\n#{oversized.join("\n")}"
  end
end
