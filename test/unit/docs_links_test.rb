# frozen_string_literal: true

require 'minitest/autorun'
require 'ripper'
require 'tmpdir'

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

class DocsDivergenceTableTest < Minitest::Test
  parallelize_me!

  SECTION = '## Divergences from the Sidekiq spec'
  LEDGER = File.join(DocsLinksTest::DOCS, 'idea/parity-divergences.md')

  def self.cells(line)
    line.strip.delete_prefix('|').delete_suffix('|').split(/(?<!\\)\|/).map(&:strip)
  end

  def self.table_separator?(text)
    cells(text).all? { |cell| cell.match?(/\A:?-{3,}:?\z/) }
  end

  def self.divergence_rows(path)
    lines = DocsLinksTest.prose_lines(path)
    start = lines.index { |(_number, text)| text.strip == SECTION }
    return [[], ["#{path}:1: missing #{SECTION}"]] unless start

    section = lines[(start + 1)..].take_while { |(_number, text)| !text.match?(/^\#{1,2}\s/) }
    rows = []
    in_table = false
    section.each_with_index do |(number, text), index|
      unless text.lstrip.start_with?('|')
        in_table = false
        next
      end

      if table_separator?(text)
        in_table = index.positive? && section[index - 1][1].lstrip.start_with?('|')
        next
      end
      rows << [number, text] if in_table
    end
    errors = rows.empty? ? ["#{path}:#{lines[start][0]}: missing divergence table data rows"] : []
    [rows, errors]
  end

  def self.ledger_entries(ledger)
    return Set.new unless File.file?(ledger)

    DocsLinksTest.prose_lines(ledger).filter_map do |(_number, text)|
      heading = text.match(/^##\s+(.+?)\s*$/)
      DocsLinksTest.slug(heading[1]) if heading
    end.to_set
  end

  def self.coverage_errors(path, ledger)
    rows, errors = divergence_rows(path)
    entries = ledger_entries(ledger)
    rows.each do |number, text|
      label = cells(text).first.to_s
      linked = text.gsub(/`[^`]*`/, '``').scan(DocsLinksTest::LINK).flatten.any? do |href|
        target, anchor = href.split('#', 2)
        File.expand_path(target, File.dirname(path)) == File.expand_path(ledger) && entries.include?(anchor)
      end
      next if linked || entries.include?(DocsLinksTest.slug(label))

      errors << "#{path}:#{number}: no ledger entry for #{label} (expected #{ledger} heading or entry-specific link)"
    end
    errors
  end

  def test_every_divergence_row_has_a_ledger_entry
    errors = %w[configuration.md api.md].flat_map do |doc|
      self.class.coverage_errors(File.join(DocsLinksTest::DOCS, doc), LEDGER)
    end

    assert_empty errors
  end

  def fixture_errors(rows, ledger: "# Ledger\n\n## Recorded difference\n", document: nil)
    Dir.mktmpdir('docs-divergence') do |dir|
      source = File.join(dir, 'configuration.md')
      target = File.join(dir, 'parity-divergences.md')
      File.write(source, document || "#{SECTION}\n\n| Area | Detail |\n|---|---|\n#{rows}")
      File.write(target, ledger) if ledger
      File.write(File.join(dir, 'other.md'), "## Recorded difference\n")
      self.class.coverage_errors(source, target)
    end
  end

  def test_valid_entry_links_and_exact_normalized_headings_pass
    rows = <<~MARKDOWN
      | [Short label](parity-divergences.md#recorded-difference) | Detail |
      | **Recorded difference** | Detail |
    MARKDOWN
    assert_empty fixture_errors(rows)
  end

  def test_an_appended_unrepresented_row_fails_at_its_source_line
    rows = <<~MARKDOWN
      | Recorded difference | Detail |
      | New difference | Detail |
    MARKDOWN
    errors = fixture_errors(rows)

    assert_equal 1, errors.size
    assert_match(/configuration\.md:6:.*New difference/, errors.first)
  end

  def test_missing_ledger_file_fails_even_with_a_matching_label
    errors = fixture_errors('| Recorded difference | Detail |', ledger: nil)

    assert_equal 1, errors.size
    assert_match(/configuration\.md:5:.*parity-divergences\.md/, errors.first)
  end

  def test_missing_heading_target_fails
    errors = fixture_errors('| [Short label](parity-divergences.md#missing) | Detail |')

    assert_equal 1, errors.size
    assert_match(/configuration\.md:5:.*Short label/, errors.first)
  end

  def test_unrelated_links_and_non_entry_anchors_do_not_cover_a_row
    [
      'other.md#recorded-difference',
      'parity-divergences.md',
      'parity-divergences.md#ledger',
      'parity-divergences.md#implementation',
      'https://example.org/parity-divergences.md#recorded-difference'
    ].each do |href|
      errors = fixture_errors("| [Short label](#{href}) | Detail |",
                              ledger: "# Ledger\n## Recorded difference\n### Implementation\n")

      assert_equal 1, errors.size, href
    end
  end

  def test_heading_correspondence_is_not_a_substring_match
    errors = fixture_errors('| Recorded | Detail |')

    assert_equal 1, errors.size
  end

  def test_headers_other_sections_and_fenced_examples_are_not_rows
    document = <<~MARKDOWN
      ## Unrelated
      | Unknown | Detail |
      |---|---|
      | Not recorded | Detail |
      #{SECTION}
      ```markdown
      | Unknown | Detail |
      |---|---|
      | Not recorded | Detail |
      ```
      | Area | Detail |
      |---|---|
      | Recorded difference | Detail |
      ## Related
      | Unknown | Detail |
      |---|---|
      | Not recorded | Detail |
    MARKDOWN
    assert_empty fixture_errors(nil, document: document)
  end

  def test_missing_section_or_table_fails_instead_of_passing_vacuously
    [
      "## Related\n",
      "#{SECTION}\nNo table\n",
      "#{SECTION}\n| Area | Detail |\n|---|---|\n",
      "```markdown\n#{SECTION}\n| Area | Detail |\n|---|---|\n| Recorded difference | Detail |\n```\n"
    ].each do |document|
      errors = fixture_errors(nil, document: document)

      assert_equal 1, errors.size
      assert_match(/configuration\.md:\d+: missing/, errors.first)
    end
  end
end

# The gate on `docs/configuration.md`'s claim that its table is "Every `ENV`
# read in `lib/`".
#
# The table said that while `WURK_API_READ_ONLY` was missing from it, which is
# the failure a completeness claim invites: an operator auditing the env surface
# from a table that calls itself complete concludes the variable does not exist,
# and a stray `WURK_API_READ_ONLY=1` then 403s every API write with nothing in
# the config to explain it.
#
# Reads are found with Ripper rather than grep, because `lib/` mentions env
# names in places that are not reads: `cli.rb`'s `NO_API_TOKEN_MESSAGE` heredoc
# shows `ENV.fetch('WURK_API_TOKEN')` as example text for an initializer, and
# comments name variables freely. A lexer sees those as string and comment
# tokens; a grep sees a read and fails the build over documentation that would
# be wrong to write.
class DocsEnvTableTest < Minitest::Test
  # Reads files and touches no Redis or shared state.
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  LIB = File.join(ROOT, 'lib')
  TABLE = File.join(ROOT, 'docs', 'configuration.md')

  NAME = /\A[A-Z][A-Z0-9_]*\z/
  READERS = %w[fetch key?].freeze
  SECTION = '## Environment variables'

  # `ENV['NAME']`, `ENV.fetch('NAME', …)`, `ENV.key?('NAME')` — the reader forms
  # in lib/, each read against a literal name. Ripper.lex is enough: an `ENV`
  # inside a string or a comment lexes as tstring_content or comment and never
  # as an on_const token. A read through a variable (`ENV[OPT_OUT_ENV]`) names
  # nothing here and is not claimed to be covered.
  def self.env_reads(path)
    tokens = Ripper.lex(File.read(path)).reject do |(_pos, type, _tok, _state)|
      %i[on_sp on_nl on_ignored_nl on_comment].include?(type)
    end

    tokens.each_index.filter_map do |at|
      next unless tokens[at][1] == :on_const && tokens[at][2] == 'ENV'

      name = literal_after(tokens, at)
      name if name&.match?(NAME)
    end
  end

  # The string literal the `ENV` at `at` is subscripted with, if it is one.
  def self.literal_after(tokens, at)
    shape = tokens[(at + 1)..(at + 4)].to_a.map { |(_pos, type, tok, _state)| [type, tok] }

    case shape
    in [[:on_lbracket, _], [:on_tstring_beg, _], [:on_tstring_content, name], *]
      name
    in [[:on_period, _], [:on_ident, reader], [:on_lparen, _], [:on_tstring_beg, _]] if READERS.include?(reader)
      tokens[at + 5]&.fetch(2)
    in _
      nil
    end
  end

  # Every variable named in the first column of the env table — including the
  # `SIDEKIQ_*` aliases and the comma-separated cells. Rows are taken from that
  # section alone, so a name appearing in one of the file's other tables cannot
  # answer for a missing row here.
  def documented
    lines = File.readlines(TABLE)
    from = lines.index { |line| line.start_with?(SECTION) }
    return if from.nil?

    section = lines[(from + 1)..].take_while { |line| !line.start_with?('## ') }
    section.select { |line| line.start_with?('| `') }
           .flat_map { |row| row.split('|')[1].to_s.scan(/`([A-Z][A-Z0-9_]*)`/) }
           .flatten.to_set
  end

  def read_in_lib
    Dir.glob(File.join(LIB, '**', '*.rb')).flat_map do |path|
      self.class.env_reads(path).map { |name| [name, path.delete_prefix("#{ROOT}/")] }
    end
  end

  def test_the_table_lists_every_env_read_in_lib
    listed = documented

    refute_nil listed, "the '#{SECTION}' section is gone from docs/configuration.md"

    missing = read_in_lib.reject { |(name, _path)| listed.include?(name) }.uniq

    assert_empty missing.map { |(name, path)| "#{name} (#{path})" },
                 'docs/configuration.md says its table is "Every `ENV` read in `lib/`" — ' \
                 'add a row, or stop claiming every'
  end
end
