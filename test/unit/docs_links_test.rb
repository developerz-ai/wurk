# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'ripper'
require 'tmpdir'

# The gate on links between the reference docs.
#
# Headings in these files are numbered (`## 7. What it does not guarantee`), so
# their GitHub slugs carry the number (`#7-what-it-does-not-guarantee`) while
# the link text does not. Four links had been written against the unnumbered
# slug and rendered as dead anchors on GitHub — silently, because a dead anchor
# scrolls nowhere instead of 404ing. Renumbering the headings would break any
# external deep link already pointing at the numbered slug, so the links are
# what gets fixed, and this is what keeps them fixed.
#
# The scan covers docs/*.md and the nested trees under docs/idea, docs/target,
# docs/wiki and docs/site: a broken link in a nested doc breaks exactly as
# silently as one at the top level, and a tree nobody scans is a tree nobody
# checks. A relative link resolves against the directory of the document that
# holds it — `../benchmarks.md` under docs/idea/ is docs/benchmarks.md — and a
# `#L<n>` anchor names a line in the file it points at, so the range is
# checked against that file's length. docs/plans is out of scope: a plan is a
# point-in-time record, not documentation anyone keeps current.
class DocsLinksTest < Minitest::Test
  # Reads files and touches no Redis or shared state.
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  DOCS = File.join(ROOT, 'docs')

  # The nested trees scanned alongside docs/*.md.
  NESTED_TREES = %w[idea target wiki site].freeze

  # The trees the scan must cover, spelled out here instead of read back from
  # NESTED_TREES: a test that iterates the constant it is checking cannot fail
  # when a name is dropped from it.
  EXPECTED_TREES = %w[idea target wiki site].freeze

  # Inline links only: [text](target). Reference-style links and bare URLs are
  # not used in these docs.
  LINK = /\[[^\]]*\]\(([^)\s]+)\)/
  HEADING = /^\#{1,6}\s+(.+?)\s*$/
  FENCE = /^\s*(?:```|~~~)/

  # A GitHub line anchor: `#L10` or `#L10-L20`. The leading L is what tells it
  # apart from a heading slug, which never carries one.
  LINE_RANGE = /\AL(\d+)(?:-L?(\d+))?\z/

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
    @anchors ||= {}
    @anchors[path] ||= begin
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
  end

  # The [first, last] line a GitHub line anchor names, or nil when the anchor
  # is a heading slug instead.
  def self.line_range(anchor)
    m = LINE_RANGE.match(anchor.to_s)
    return nil unless m

    [m[1].to_i, (m[2] || m[1]).to_i]
  end

  # Every markdown file the gate scans under a docs root: the top level plus
  # the nested trees.
  def self.scanned_paths(docs)
    top = Dir.glob(File.join(docs, '*.md'))
    nested = NESTED_TREES.flat_map { |tree| Dir.glob(File.join(docs, tree, '**', '*.md')) }
    (top + nested).sort
  end

  # Every intra-repo link in the scanned documents, with the source it came
  # from — a link's meaning depends on the file it sits in.
  def self.links(paths)
    paths.flat_map do |path|
      prose_lines(path).flat_map do |(line_no, text)|
        # A table cell reading `[](name)` is a code span, not a link.
        text.gsub(/`[^`]*`/, '``').scan(LINK).flatten.filter_map do |href|
          next if href.start_with?('http://', 'https://', 'mailto:', '<')

          target, anchor = href.split('#', 2)
          { path: path, line: line_no, href: href, target: target, anchor: anchor }
        end
      end
    end
  end

  # Where a link points. A relative link resolves against the directory of the
  # document that holds it, so `../benchmarks.md` under docs/idea/ is
  # docs/benchmarks.md and not docs/idea/benchmarks.md.
  def self.resolve(link)
    target = link[:target].to_s
    return link[:path] if target.empty?

    File.expand_path(target, File.dirname(link[:path]))
  end

  # A path as the docs tree names it: relative to the directory holding the
  # docs root, so a finding reads `docs/idea/notes.md:12`.
  def self.display(path, docs)
    path.delete_prefix("#{File.dirname(docs)}/")
  end

  # A same-file #anchor must name a heading in that file.
  def self.same_file_anchor_errors(paths, docs)
    links(paths).filter_map do |link|
      next unless link[:target].to_s.empty?
      next if line_range(link[:anchor])
      next if anchors(link[:path]).include?(link[:anchor])

      "#{display(link[:path], docs)}:#{link[:line]} -> ##{link[:anchor]}"
    end
  end

  # A relative link must resolve to a file in the repo.
  def self.missing_target_errors(paths, docs)
    links(paths).filter_map do |link|
      next if link[:target].to_s.empty?
      next if File.exist?(resolve(link))

      "#{display(link[:path], docs)}:#{link[:line]} -> #{link[:target]}"
    end
  end

  # A link into another doc must name a heading that exists there.
  def self.cross_doc_anchor_errors(paths, docs)
    links(paths).filter_map do |link|
      next if link[:target].to_s.empty? || link[:anchor].nil?
      next unless link[:target].end_with?('.md')
      next if line_range(link[:anchor])

      path = resolve(link)
      next if File.exist?(path) && anchors(path).include?(link[:anchor])

      "#{display(link[:path], docs)}:#{link[:line]} -> #{link[:href]}"
    end
  end

  # A #L<n> / #L<n>-L<m> anchor must fall inside the file it points at.
  def self.line_range_errors(paths, docs)
    links(paths).filter_map do |link|
      range = line_range(link[:anchor])
      next unless range

      path = resolve(link)
      next unless File.file?(path)

      count = File.readlines(path).size
      next if range[0].between?(1, range[1]) && range[1] <= count

      "#{display(link[:path], docs)}:#{link[:line]} -> #{link[:href]} (the target has #{count} lines)"
    end
  end

  def paths
    @paths ||= self.class.scanned_paths(DOCS)
  end

  def test_every_intra_doc_anchor_names_a_heading
    assert_empty self.class.same_file_anchor_errors(paths, DOCS),
                 'an #anchor must match a heading in the same file — headings here are ' \
                 'numbered, so the slug is (e.g.) #7-what-it-does-not-guarantee'
  end

  def test_every_relative_link_resolves_to_a_file
    assert_empty self.class.missing_target_errors(paths, DOCS),
                 'a relative link must resolve to a file in the repo'
  end

  def test_every_cross_doc_anchor_names_a_heading_in_that_doc
    assert_empty self.class.cross_doc_anchor_errors(paths, DOCS),
                 'a link into another doc must name a heading that exists there'
  end

  def test_every_line_range_anchor_is_inside_its_target_file
    assert_empty self.class.line_range_errors(paths, DOCS),
                 'a #L<n> / #L<n>-L<m> anchor must fall inside the file it points at'
  end

  # The gate's findings on a tmpdir docs tree, keyed by the check that made
  # them. The real tree is clean, so a broken nested doc has to be built to
  # prove the gate would report one. `scanned` counts the links the gate read,
  # which is what proves the nested doc was read at all — an unsanned tree
  # reports nothing, and nothing would look like a pass.
  def fixture_errors(files)
    Dir.mktmpdir('docs-links') do |dir|
      files.each do |name, content|
        path = File.join(dir, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end

      docs = File.join(dir, 'docs')
      paths = self.class.scanned_paths(docs)
      {
        scanned: self.class.links(paths).size,
        missing: self.class.missing_target_errors(paths, docs),
        cross_doc: self.class.cross_doc_anchor_errors(paths, docs),
        same_file: self.class.same_file_anchor_errors(paths, docs),
        line_range: self.class.line_range_errors(paths, docs)
      }
    end
  end

  # Every name in the scanned trees is a tree the gate actually reads, not just
  # the ones the other fixtures happen to use: dropping one from NESTED_TREES
  # would leave that tree unchecked and the suite green, which is what this
  # pins.
  def test_every_nested_tree_is_scanned
    assert_equal EXPECTED_TREES.sort, NESTED_TREES.sort,
                 'a tree added to NESTED_TREES needs a fixture here too'

    EXPECTED_TREES.each do |tree|
      errors = fixture_errors("docs/#{tree}/nested.md" => "[gone](../../lib/wurk/missing.rb)\n")

      assert_equal 1, errors[:scanned], tree
      assert_equal 1, errors[:missing].size, tree
      assert_match(%r{docs/#{tree}/nested\.md:1 -> \.\./\.\./lib/wurk/missing\.rb}, errors[:missing].first, tree)
    end
  end

  def test_a_nested_doc_link_to_a_missing_file_is_reported
    errors = fixture_errors('docs/idea/nested.md' => "[gone](../../lib/wurk/missing.rb)\n")

    assert_equal 1, errors[:scanned]
    assert_equal 1, errors[:missing].size
    assert_match(%r{docs/idea/nested\.md:1 -> \.\./\.\./lib/wurk/missing\.rb}, errors[:missing].first)
  end

  # The scan recurses: a doc two levels down a tree is read like any other, so
  # a tree that grows a subdirectory later is covered without a code change.
  def test_a_doc_deeper_in_a_nested_tree_is_scanned
    errors = fixture_errors('docs/idea/sub/deep.md' => "[gone](../../../lib/wurk/missing.rb)\n")

    assert_equal 1, errors[:scanned]
    assert_equal 1, errors[:missing].size
    assert_match(%r{docs/idea/sub/deep\.md:1 -> \.\./\.\./\.\./lib/wurk/missing\.rb}, errors[:missing].first)
  end

  def test_a_nested_doc_anchor_to_a_missing_heading_is_reported
    errors = fixture_errors('docs/idea/nested.md' => "[gone](#no-such-heading)\n")

    assert_equal 1, errors[:scanned]
    assert_equal 1, errors[:same_file].size
    assert_match(%r{docs/idea/nested\.md:1 -> #no-such-heading}, errors[:same_file].first)
  end

  def test_a_cross_doc_anchor_to_a_missing_heading_is_reported
    errors = fixture_errors(
      'docs/idea/nested.md' => "[gone](../target/spec.md#no-such-heading)\n",
      'docs/target/spec.md' => "# Spec\n\nBody\n"
    )

    assert_equal 1, errors[:scanned]
    assert_equal 1, errors[:cross_doc].size
    assert_match(%r{docs/idea/nested\.md:1 -> .*#no-such-heading}, errors[:cross_doc].first)
  end

  def test_a_cross_doc_anchor_to_a_real_heading_passes
    errors = fixture_errors(
      'docs/idea/nested.md' => "[here](../target/spec.md#spec)\n",
      'docs/target/spec.md' => "# Spec\n\nBody\n"
    )

    assert_equal 1, errors[:scanned]
    assert_empty errors[:missing]
    assert_empty errors[:cross_doc]
  end

  def test_a_line_range_outside_the_target_file_is_reported
    errors = fixture_errors(
      'docs/idea/nested.md' => "[a](../../lib/wurk/client.rb#L100-L200)\n[b](../../lib/wurk/client.rb#L31)\n",
      'lib/wurk/client.rb' => "line\n" * 30
    )

    assert_equal 2, errors[:scanned]
    assert_equal 2, errors[:line_range].size
    assert_match(%r{docs/idea/nested\.md:1 -> .*#L100-L200}, errors[:line_range].first)
    assert_match(%r{docs/idea/nested\.md:2 -> .*#L31}, errors[:line_range].last)
  end

  def test_a_line_range_inside_the_target_file_passes
    errors = fixture_errors(
      'docs/idea/nested.md' => "[a](../../lib/wurk/client.rb#L10-L20)\n[b](../../lib/wurk/client.rb#L30)\n",
      'lib/wurk/client.rb' => "line\n" * 30
    )

    # An empty missing list is what proves the target was found and read: a
    # link that resolved nowhere is skipped, not passed.
    assert_equal 2, errors[:scanned]
    assert_empty errors[:missing]
    assert_empty errors[:line_range]
  end

  def test_a_line_range_into_a_doc_is_not_read_as_a_heading_anchor
    errors = fixture_errors(
      'docs/idea/nested.md' => "[a](../target/spec.md#L5)\n",
      'docs/target/spec.md' => "# Spec\n\n#{"Body\n" * 8}"
    )

    assert_equal 1, errors[:scanned]
    assert_empty errors[:missing]
    assert_empty errors[:cross_doc]
    assert_empty errors[:line_range]
  end

  # A same-file #L<n> resolves to the document that holds it, so its range is
  # measured against that document's own length — the branch resolve takes for
  # an empty target.
  def test_a_same_file_line_range_outside_the_file_is_reported
    errors = fixture_errors('docs/idea/nested.md' => "[a](#L99)\n\nbody\n")

    assert_equal 1, errors[:scanned]
    assert_equal 1, errors[:line_range].size
    assert_match(%r{docs/idea/nested\.md:1 -> #L99}, errors[:line_range].first)
    assert_empty errors[:same_file]
  end

  def test_a_same_file_line_range_inside_the_file_passes
    errors = fixture_errors('docs/idea/nested.md' => "[a](#L2)\n\nbody\n")

    assert_equal 1, errors[:scanned]
    assert_empty errors[:missing]
    assert_empty errors[:line_range]
  end

  # A directory target has no lines to read: File.exist? is true for one, so
  # reading it as a file raised Errno::EISDIR instead of checking the range.
  def test_a_line_range_into_a_directory_is_skipped
    errors = fixture_errors(
      'docs/idea/nested.md' => "[a](../target#L5)\n",
      'docs/target/spec.md' => "# Spec\n"
    )

    assert_equal 1, errors[:scanned]
    assert_empty errors[:line_range]
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
