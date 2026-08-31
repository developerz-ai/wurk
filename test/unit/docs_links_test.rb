# frozen_string_literal: true

require 'minitest/autorun'

# The gate on links between the reference docs in docs/*.md.
#
# Headings in these files are numbered (`## 7. What it does not guarantee`), so
# their GitHub slugs carry the number (`#7-what-it-does-not-guarantee`) while
# the link text does not. Four links had been written against the unnumbered
# slug and rendered as dead anchors on GitHub — silently, because a dead anchor
# scrolls nowhere instead of 404ing. Renumbering the headings would break any
# external deep link already pointing at the numbered slug, so the links are
# what gets fixed, and this is what keeps them fixed.
class DocsLinksTest < Minitest::Test
  # Reads files and touches no Redis or shared state.
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  DOCS = File.join(ROOT, 'docs')

  # Inline links only: [text](target). Reference-style links and bare URLs are
  # not used in these docs.
  LINK = /\[[^\]]*\]\(([^)\s]+)\)/
  HEADING = /^\#{1,6}\s+(.+?)\s*$/
  FENCE = /^\s*(?:```|~~~)/

  # GitHub's heading-anchor algorithm: strip inline markdown, downcase, drop
  # everything that is not a word character, a space or a hyphen, then turn
  # spaces into hyphens. `## 7. What it does not guarantee` becomes
  # `7-what-it-does-not-guarantee`.
  def self.slug(heading)
    text = heading.gsub(/`([^`]*)`/, '\1')          # code spans
                  .gsub(/\*\*?([^*]*)\*\*?/, '\1')  # bold / italic
                  .gsub(/\[([^\]]*)\]\([^)]*\)/, '\1') # links keep their text
    text.downcase.gsub(/[^\p{Word}\- ]/u, '').tr(' ', '-')
  end

  # Lines outside fenced code blocks, as [line number, line].
  def self.prose_lines(path)
    fenced = false
    File.readlines(path).each_with_index.filter_map do |line, i|
      if line.match?(FENCE)
        fenced = !fenced
        next
      end
      next if fenced

      [i + 1, line]
    end
  end

  # Every anchor a heading in this file answers to. GitHub disambiguates
  # repeated headings by appending -1, -2, … in document order.
  def self.anchors(path)
    seen = Hash.new(0)
    prose_lines(path).filter_map do |(_line_no, text)|
      m = text.match(HEADING)
      next unless m

      base = slug(m[1])
      n = seen[base]
      seen[base] += 1
      n.zero? ? base : "#{base}-#{n}"
    end.to_set
  end

  def docs
    @docs ||= Dir.children(DOCS).select { |f| f.end_with?('.md') }.sort
  end

  def anchors_for(path)
    (@anchors ||= {})[path] ||= self.class.anchors(path)
  end

  # target, anchor and source location for every intra-repo link in docs/*.md.
  def links
    docs.flat_map do |doc|
      path = File.join(DOCS, doc)
      self.class.prose_lines(path).flat_map do |(line_no, text)|
        # A table cell reading `[](name)` is a code span, not a link.
        text.gsub(/`[^`]*`/, '``').scan(LINK).flatten.filter_map do |href|
          next if href.start_with?('http://', 'https://', 'mailto:', '<')

          target, anchor = href.split('#', 2)
          { doc: doc, line: line_no, href: href, target: target, anchor: anchor }
        end
      end
    end
  end

  def test_every_intra_doc_anchor_names_a_heading
    broken = links.select { |l| l[:target].to_s.empty? }.reject do |l|
      anchors_for(File.join(DOCS, l[:doc])).include?(l[:anchor])
    end

    assert_empty broken.map { |l| "#{l[:doc]}:#{l[:line]} -> ##{l[:anchor]}" },
                 'an #anchor must match a heading in the same file — headings here are ' \
                 'numbered, so the slug is (e.g.) #7-what-it-does-not-guarantee'
  end

  def test_every_relative_link_resolves_to_a_file
    broken = links.reject { |l| l[:target].to_s.empty? }.reject do |l|
      File.exist?(File.expand_path(l[:target], DOCS))
    end

    assert_empty broken.map { |l| "#{l[:doc]}:#{l[:line]} -> #{l[:target]}" },
                 'a relative link must resolve to a file in the repo'
  end

  def test_every_cross_doc_anchor_names_a_heading_in_that_doc
    candidates = links.reject { |l| l[:target].to_s.empty? || l[:anchor].nil? }
                      .select { |l| l[:target].end_with?('.md') }

    broken = candidates.reject do |l|
      path = File.expand_path(l[:target], DOCS)
      File.exist?(path) && anchors_for(path).include?(l[:anchor])
    end

    assert_empty broken.map { |l| "#{l[:doc]}:#{l[:line]} -> #{l[:href]}" },
                 'a link into another doc must name a heading that exists there'
  end
end
