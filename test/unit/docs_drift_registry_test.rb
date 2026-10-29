# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

# The gate on the docs-drift guard registry: the table in
# .dz/schedules/docs-drift.md that tells the scout which guard tests already
# police a claim on a documentation surface, so the lane never re-reports a
# claim a gate already covers.
#
# The registry is only worth what it says, so this test proves three things:
#
#   1. Every row's `path:line` anchor lands on the `class <Name> <` line of the
#      guard class the row names. An anchor that points at a method, or at a
#      different class, sends the lane to the wrong guard.
#   2. The rows are exactly the guard classes the discovery rule finds: a test
#      class under test/unit/ whose OWN CODE reads a documentation surface
#      (README.md, CLAUDE.md, CONTRIBUTING.md, RELEASE.md, or a file under
#      docs/) — directly, or through a method of its file while its own code
#      builds a surface path. A guard that only NAMES a surface in an
#      assertion message owns no claim on it; a guard that reads one does, and
#      the registry must say so or the lane re-reports a claim a gate already
#      covers. Sibling classes in one file are judged separately: a class that
#      reads fixtures next to a class that reads docs owns no claim on docs.
#   3. The brief carries the criterion the registry is held to, and carries it
#      once: the old `| Guard | What it owns |` table and the `## Rows` bullet
#      list are merged into the one registry table.
#
# Completeness comes from the discovery rule, never from a copy of the
# registry: the rule is re-derived from the test tree on every run, so a new
# doc-surface guard fails this gate until the brief names it.
#
# Every rejection below is proven on a COPY of the registry text. The committed
# brief is never rewritten by a test.
#
# Reads files only; touches no Redis and no shared state.
class DocsDriftRegistryTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  BRIEF_PATH = File.join(ROOT, '.dz', 'schedules', 'docs-drift.md')
  UNIT_GLOB = File.join(ROOT, 'test', 'unit', '**', '*_test.rb')

  REGISTRY_HEADING = '## Guard registry'
  TABLE_HEADER = ['Ask slug', 'Guard anchor', 'Guard class', 'Claim it owns'].freeze
  OLD_TABLE_HEADER = '| Guard | What it owns |'

  # The criterion the registry is held to, verbatim: the brief carries it so a
  # reader knows what a row means, and this gate holds the brief to it.
  CRITERION = 'A guard qualifies for this registry when it is a test class under ' \
              '`test/unit/` that reads a documentation surface — `README.md`, ' \
              '`CLAUDE.md`, `CONTRIBUTING.md`, `RELEASE.md`, or a file under `docs/`. ' \
              'Ownership is per claim: a guard that owns one claim on a surface owns ' \
              'no other claim on it, and this lane keeps reporting the claims no guard owns.'

  # The documentation surfaces a guard can own a claim on.
  SURFACE_FILES = %w[README.md CLAUDE.md CONTRIBUTING.md RELEASE.md].freeze
  DOCS_PREFIX = 'docs/'

  # A path segment only known at runtime: `File.join(DOCS, doc)` builds
  # docs/<something>, so the join's prefix decides — a `docs/` prefix
  # qualifies, any other prefix does not.
  WILDCARD = "\u0000"

  # The calls that read a file's content. `File.size`/`File.exist?` are not
  # reads: they see that a file is there, not what it says. The argument
  # pattern holds one level of nested call, so a read of a path the guard
  # builds is read whole: `File.readlines(File.join(DOCS, 'x.md'))`.
  READ_CALLS = {
    'File.readlines' => /File\.readlines\(((?:[^()]|\([^()]*\))*)\)/m,
    'File.read' => /File\.read\(((?:[^()]|\([^()]*\))*)\)/m,
    'File.open' => /File\.open\(((?:[^()]|\([^()]*\))*)\)/m,
    'IO.read' => /IO\.read\(((?:[^()]|\([^()]*\))*)\)/m,
    'Dir.glob' => /Dir\.glob\(((?:[^()]|\([^()]*\))*)\)/m,
    'Dir[' => /Dir\[(.*?)\]/m
  }.freeze

  def test_the_committed_registry_satisfies_the_gate
    errors = registry_errors(brief_text)

    assert_empty errors,
                 "the docs-drift brief's guard registry must satisfy the gate:\n#{errors.join("\n")}"
  end

  def test_the_brief_carries_the_criterion_the_registry_is_held_to
    assert_includes normalize(brief_text), normalize(CRITERION),
                    'the brief must carry the criterion that says what a registry row is'
  end

  def test_the_registry_table_carries_the_four_columns
    header, = parse_registry(brief_text)

    assert_equal TABLE_HEADER, header,
                 "the registry table's header must be #{TABLE_HEADER.join(' | ')}"
  end

  def test_every_row_anchor_lands_on_the_guard_class_it_names
    assert_empty anchor_errors(registry_rows),
                 'every registry anchor must land on the `class <Name> <` line of the guard it names'
  end

  def test_the_registry_lists_exactly_the_guards_that_read_a_documentation_surface
    assert_empty membership_errors(registry_rows),
                 'the registry must list every guard that reads a documentation surface, ' \
                 'and nothing else'
  end

  # A guard that reads a documentation surface through a docs-DIRECTORY
  # constant is a guard. The repo's own pattern is docs_links_test.rb: `DOCS =
  # File.join(ROOT, 'docs')` holds the docs directory, and `LEDGER =
  # File.join(DOCS, 'idea/parity-divergences.md')` reads a file under it. The
  # constant has to be resolved to its own literal segments, or the read
  # collapses to `idea/parity-divergences.md`, which names no surface, and the
  # guard goes unlisted.
  #
  # The fixture is written as quoted lines, not a heredoc: a heredoc's lines
  # start with the constant's name, so the discovery rule would find THIS
  # file's copy of that assignment and read this gate as a guard that reads a
  # documentation surface. It owns no claim on one.
  def test_a_guard_reading_a_surface_through_a_docs_directory_constant_is_discovered
    fixture = [
      'class FixtureGuardTest < Minitest::Test',
      "  ROOT = File.expand_path('../..', __dir__)",
      "  DOCS = File.join(ROOT, 'docs')",
      "  LEDGER = File.join(DOCS, 'idea/parity-divergences.md')",
      '  def test_it',
      '    File.readlines(LEDGER)',
      '  end',
      'end'
    ].join("\n")

    Dir.mktmpdir('docs-drift-registry') do |dir|
      path = File.join(dir, 'fixture_guard_test.rb')
      File.write(path, fixture)

      assert_equal [['FixtureGuardTest', 1]], class_guards(path),
                   'a guard that reads a doc surface through a docs-directory constant reads a doc surface'
    end
  end

  # Sibling classes in one file are judged separately. Discovery read the
  # whole FILE, so one reading class registered its non-reading siblings too,
  # and the gate demanded rows for classes that own no claim on any
  # documentation surface. Both siblings here read a file; only the one whose
  # own code builds a docs path qualifies. The constants are quoted lines,
  # unresolvable in THIS file, for the reason the fixture above gives.
  def test_only_the_qualifying_sibling_in_a_file_is_discovered
    fixture = [
      'class FixtureSurfaceGuardTest < Minitest::Test',
      "  BOOKS = File.join(SHELF, 'docs')",
      "  OVERVIEW = File.join(BOOKS, 'overview.md')",
      '  def test_it',
      '    File.readlines(OVERVIEW)',
      '  end',
      'end',
      'class FixtureOfflineTest < Minitest::Test',
      "  CACHE = File.join(SHELF, 'tmp', 'cache.db')",
      '  def test_it',
      '    File.readlines(CACHE)',
      '  end',
      'end'
    ].join("\n")

    Dir.mktmpdir('docs-drift-registry') do |dir|
      path = File.join(dir, 'fixture_siblings_test.rb')
      File.write(path, fixture)

      assert_equal [['FixtureSurfaceGuardTest', 1]], class_guards(path),
                   'only the sibling whose own code reads a documentation surface is a guard'
    end
  end

  def test_the_registry_has_no_duplicate_slug_class_or_anchor
    assert_empty duplicate_errors(registry_rows),
                 'a duplicate slug, guard class or anchor is a second copy of the same guard'
  end

  def test_the_brief_carries_one_registry
    assert_empty one_registry_errors(brief_text, registry_rows),
                 'the old guard table and the `## Rows` bullet list are merged into the one registry'
  end

  # A wrong anchor: the row still names a real guard, but its `path:line` no
  # longer lands on that guard's definition line.
  def test_a_row_whose_anchor_misses_its_guard_class_is_rejected
    mutated = mutate_first_row(brief_text) { |row| row[1] = "`#{anchor_path(row[1])}:1`" }

    refute_equal brief_text, mutated, 'the mutation must change the registry copy'
    assert_match('does not land on the `class', registry_errors(mutated).join("\n"),
                 'a row whose anchor misses its guard class must be rejected')
  end

  # A missing row: a guard that reads a documentation surface is left out, so
  # the lane would re-report a claim that guard already covers.
  def test_a_missing_qualifying_row_is_rejected
    mutated = drop_first_row(brief_text)

    refute_equal brief_text, mutated, 'the mutation must change the registry copy'
    assert_match('does not list', registry_errors(mutated).join("\n"),
                 'a qualifying guard with no registry row must be rejected')
  end

  # A wrong class name: the row names a class the discovery rule does not find.
  def test_a_row_naming_a_class_the_discovery_rule_does_not_find_is_rejected
    mutated = mutate_first_row(brief_text) { |row| row[2] = '`NoSuchGuardTest`' }

    refute_equal brief_text, mutated, 'the mutation must change the registry copy'
    assert_match('no guard class', registry_errors(mutated).join("\n"),
                 'a row naming a class the discovery rule does not find must be rejected')
  end

  # A duplicate: the same guard listed twice under two slugs.
  def test_a_duplicate_slug_or_class_is_rejected
    mutated = duplicate_first_row(brief_text)

    refute_equal brief_text, mutated, 'the mutation must change the registry copy'
    assert_match('appears more than once', registry_errors(mutated).join("\n"),
                 'a duplicated slug or guard class must be rejected')
  end

  # A whole-surface claim: a row whose claim is only the surface claims every
  # claim on that surface, and the lane would stop reporting it.
  def test_a_row_that_claims_a_whole_surface_is_rejected
    mutated = mutate_first_row(brief_text) { |row| row[3] = 'README.md' }

    refute_equal brief_text, mutated, 'the mutation must change the registry copy'
    assert_match('claims the whole surface', registry_errors(mutated).join("\n"),
                 'a row that claims a whole documentation surface must be rejected')
  end

  private

  def brief_text
    @brief_text ||= File.read(BRIEF_PATH)
  end

  def registry_rows
    @registry_rows ||= parse_registry(brief_text).last
  end

  # Everything wrong with a registry text, one error per problem. The
  # committed brief and every mutated copy go through the same checker.
  def registry_errors(text)
    header, rows = parse_registry(text)
    return ["the brief must carry a `#{REGISTRY_HEADING}` section with a registry table"] if header.nil?

    errors = []
    unless header == TABLE_HEADER
      errors << "the registry table's header must be #{TABLE_HEADER.join(' | ')}, got #{header.inspect}"
    end
    errors.concat(cell_errors(rows))
    errors.concat(duplicate_errors(rows))
    errors.concat(anchor_errors(rows))
    errors.concat(membership_errors(rows))
    errors.concat(one_registry_errors(text, rows))
    errors
  end

  # The registry table's header cells and its data rows, each row four cells.
  def parse_registry(text)
    section = section_after(text, REGISTRY_HEADING)
    return [nil, []] if section.nil?

    table = section.select { |line| line.strip.start_with?('|') }
    return [nil, []] if table.empty?

    header = cells(table.first)
    rows = table.drop(1).reject { |line| separator?(line) }.map { |line| cells(line) }
    [header, rows]
  end

  # The lines between a heading and the next heading of the same level.
  def section_after(text, heading)
    lines = text.lines
    index = lines.index { |line| line.strip == heading }
    return nil if index.nil?

    lines[(index + 1)..].take_while { |line| !line.start_with?('## ') }
  end

  def cells(line)
    line.strip.delete_prefix('|').delete_suffix('|').split(/(?<!\\)\|/).map(&:strip)
  end

  def separator?(line)
    row = cells(line)
    row.any? && row.all? { |cell| cell.match?(/\A:?-{3,}:?\z/) }
  end

  def data_row?(line)
    line.strip.start_with?('|') && !separator?(line) && cells(line) != TABLE_HEADER
  end

  # Each cell's shape: the first three are single backticked tokens, the
  # fourth is prose.
  def cell_errors(rows)
    errors = []
    rows.each_with_index do |row, index|
      position = index + 1
      if row.size != TABLE_HEADER.size
        errors << "registry row #{position} must have #{TABLE_HEADER.size} cells, got #{row.size}"
        next
      end

      slug, anchor, guard, claim = row
      unless slug.match?(/\A`[a-z0-9]+(?:-[a-z0-9]+)*`\z/)
        errors << "registry row #{position}: the ask slug #{slug.inspect} must be a backticked kebab-case token"
      end
      unless anchor.match?(/\A`[^`:\s]+:\d+`\z/)
        errors << "registry row #{position}: the anchor #{anchor.inspect} must be a backticked path:line token"
      end
      unless guard.match?(/\A`[A-Z][A-Za-z0-9_]*`\z/)
        errors << "registry row #{position}: the guard class #{guard.inspect} must be a backticked class name"
      end
      if claim.strip.empty?
        errors << "registry row #{position}: the claim it owns must be prose, got #{claim.inspect}"
      elsif whole_surface?(claim.strip)
        errors << "registry row #{position}: the claim #{claim.inspect} claims the whole surface; " \
                  'a row owns one claim on a surface, not every claim on it'
      end
    end
    errors
  end

  def duplicate_errors(rows)
    errors = []
    { 'slug' => 0, 'guard class' => 2, 'anchor' => 1 }.each do |label, column|
      values = rows.filter_map { |row| row[column] }
      values.tally.select { |_value, count| count > 1 }.each_key do |value|
        errors << "the registry's #{label} #{value.inspect} appears more than once"
      end
    end
    errors
  end

  # Every anchor must resolve to the `class <Name> <` line of the guard it
  # names: that is where a reader (and the lane) goes to read the guard.
  def anchor_errors(rows)
    errors = []
    rows.each do |row|
      next unless row.size == TABLE_HEADER.size

      path, number = anchor_target(row[1])
      file = File.join(ROOT, path)
      unless File.file?(file)
        errors << "the anchor #{row[1]} names a file that does not exist"
        next
      end

      lines = File.readlines(file)
      unless number.between?(1, lines.size)
        errors << "the anchor #{row[1]} points past the end of #{path}"
        next
      end

      guard = row[2].delete('`')
      unless lines[number - 1].match?(/^\s*class\s+#{Regexp.escape(guard)}\s*</)
        errors << "the anchor #{row[1]} does not land on the `class #{guard} <` line of #{path}"
      end
    end
    errors
  end

  # The rows and the discovery rule must be the same set: every guard that
  # reads a documentation surface is listed, and nothing else is.
  def membership_errors(rows)
    listed = rows.filter_map do |row|
      next unless row.size == TABLE_HEADER.size

      "#{anchor_path(row[1])}:#{row[2].delete('`')}"
    end
    discovered = discovered_guards.map { |guard| "#{guard[:path]}:#{guard[:name]}" }

    errors = (discovered - listed).map do |guard|
      "the registry does not list #{guard}, a guard that reads a documentation surface"
    end
    errors.concat((listed - discovered).map do |guard|
      "the registry lists #{guard}, which no guard class reads a documentation surface for"
    end)
    errors
  end

  # One registry, not two: the old guard table is gone and every ask slug
  # appears exactly once in the brief.
  def one_registry_errors(text, rows)
    errors = []
    if text.include?(OLD_TABLE_HEADER)
      errors << "the brief must carry ONE registry: the old `#{OLD_TABLE_HEADER}` table is still there"
    end

    rows.each do |row|
      next unless row.size == TABLE_HEADER.size

      slug = row[0].delete('`')
      count = text.scan("`#{slug}`").size
      next unless count > 1

      errors << "the ask slug #{slug.inspect} appears more than once in the brief; the registry is duplicated"
    end
    errors
  end

  # The discovery rule: every test class under test/unit/ whose own code reads
  # a documentation surface. Sibling classes in one file are judged on their
  # own bodies, so a file where one class reads docs does not turn the others
  # into guards.
  def discovered_guards
    @discovered_guards ||= Dir.glob(UNIT_GLOB).flat_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      class_guards(path).map { |name, line| { path: relative, name: name, line: line } }
    end
  end

  # The qualifying guard classes of one file, in file order, each with its
  # 1-based definition line — the line a registry row anchors to.
  def class_guards(path)
    lines = File.readlines(path)
    file_code = without_comments(lines)
    readers = reading_helpers(file_code)
    class_bodies(lines).filter_map do |name, number, body|
      next unless class_reads_surface?(without_comments(body.lines), file_code, readers)

      [name, number]
    end
  end

  # Each class definition in the file, in order: its name, its definition
  # line, and its raw body — the class's own lines through the line before the
  # next class definition. Sequential slicing also keeps a nested class's code
  # out of its parent's body.
  def class_bodies(lines)
    starts = lines.each_with_index.filter_map do |line, index|
      match = line.match(/^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)\s</)
      match && [match[1], index]
    end
    starts.each_with_index.map do |(name, index), at|
      stop = starts[at + 1]&.last || lines.size
      [name, index + 1, lines[index...stop].join]
    end
  end

  # Whether one class's own code reads a documentation surface: a content read
  # whose argument names a surface, or — when the class reads files through a
  # method of its file, the way DocsDivergenceTableTest reads the ledger
  # through DocsLinksTest.prose_lines — a surface path its own code builds.
  # The surface evidence keeps a helper that reads NON-docs files from
  # qualifying every class that calls one.
  def class_reads_surface?(body, file_code, readers)
    reads_documentation_surface?(body, file_code) ||
      (invokes_reading_helper?(body, readers) && builds_surface_path?(body, file_code))
  end

  # Whether the code reads a documentation surface: one of its content-read
  # calls consumes a path under `docs/`, or one of the four named files.
  # Constants resolve against the whole file's code, since a class may name a
  # constant a sibling class holds (`DocsLinksTest::DOCS`).
  def reads_documentation_surface?(code, file_code)
    read_arguments(code).any? do |argument|
      names_surface?(argument + resolved_constants(file_code, argument), file_code)
    end
  end

  # The file's methods whose own slice — the `def` line through the line
  # before the next `def`, at any indentation, in any class of the file —
  # holds a content-read call.
  def reading_helpers(code)
    lines = code.lines
    starts = lines.each_with_index.filter_map do |line, index|
      match = line.match(/^\s*def\s+(?:self\.)?([a-z_][a-z0-9_]*)\b/)
      match && [match[1], index]
    end
    starts.filter_map.with_index do |(name, index), at|
      stop = starts[at + 1]&.last || lines.size
      next unless READ_CALLS.values.any? { |pattern| lines[index...stop].join.match?(pattern) }

      name
    end
  end

  def invokes_reading_helper?(body, readers)
    readers.any? { |name| body.match?(/\b#{Regexp.escape(name)}\s*\(/) }
  end

  # Whether the code BUILDS a documentation-surface path with `File.join` —
  # the evidence that a class reading files through a shared helper reads
  # documentation and not fixtures or caches.
  def builds_surface_path?(body, file_code)
    joined_paths(body, file_code).any? { |path| surface_path?(path) }
  end

  def without_comments(lines)
    lines.reject { |line| line.strip.start_with?('#') }.join
  end

  # The argument text of every content-read call in the code.
  def read_arguments(code)
    READ_CALLS.values.flat_map { |pattern| code.scan(pattern).flatten }
  end

  # The assignment text of the constants a read's argument names: the read
  # consumes the path the constant holds.
  def resolved_constants(code, argument)
    argument.scan(/\b[A-Z][A-Z0-9_]*\b/).filter_map { |name| constant_assignment(code, name) }.join(' ')
  end

  def constant_assignment(code, name)
    match = code.match(/^\s*#{Regexp.escape(name)}\s*=(?!=)\s*(.+)$/)
    match && match[1]
  end

  # Whether the text names a documentation surface, either as a literal path or
  # as a path `File.join` builds from literal segments.
  def names_surface?(text, code)
    string_literals(text).any? { |literal| surface_path?(literal) } ||
      joined_paths(text, code).any? { |path| surface_path?(path) }
  end

  def string_literals(text)
    text.scan(/'[^'\n]*'|"[^"\n]*"/).map { |literal| literal[1..-2] }
  end

  # The paths the text's `File.join` calls build.
  def joined_paths(text, code)
    text.scan(/File\.join\(([^)]*)\)/).map { |(arguments)| joined_path(arguments, code) }
  end

  # The path one `File.join` builds.
  def joined_path(arguments, code)
    join_segments(arguments, code).join('/')
  end

  # The path segments a `File.join`'s arguments hold, in order: each string
  # literal, the segments of the constant it names, or a WILDCARD for a
  # segment only known at runtime (`doc`, a block variable).
  def join_segments(arguments, code)
    scan = /'[^'\n]*'|"[^"\n]*"|\b[A-Z][A-Z0-9_]*(?:::[A-Z][A-Z0-9_]*)*\b|\b[a-z_][a-z0-9_]*\b/
    arguments.scan(scan).flat_map do |item|
      if item.start_with?("'", '"')
        [item[1..-2]]
      elsif item.match?(/\A[A-Z]/)
        constant_segments(item.split('::').last, code)
      else
        [WILDCARD]
      end
    end
  end

  # The path segments a constant holds: the `File.join` its own assignment
  # builds, resolved the same way. `DOCS = File.join(ROOT, 'docs')` holds
  # `docs`, so `File.join(DOCS, 'x.md')` reads `docs/x.md`.
  def constant_segments(name, code)
    assignment = constant_assignment(code, name)
    return [] if assignment.nil?

    join = assignment.match(/File\.join\((.*)\)/)
    return [] if join.nil?

    join_segments(join[1], code)
  end

  def surface_path?(path)
    return true if SURFACE_FILES.include?(path)

    path.start_with?(DOCS_PREFIX) && path.length > DOCS_PREFIX.length
  end

  # Whether the text IS a documentation surface, with nothing else on it: a
  # claim that is only a path claims every claim on that surface.
  def whole_surface?(text)
    return true if SURFACE_FILES.include?(text)

    surface_path?(text) && !text.include?(' ')
  end

  def anchor_target(anchor)
    path, number = anchor.delete('`').split(':', 2)
    [path, number.to_i]
  end

  def anchor_path(anchor)
    anchor_target(anchor).first
  end

  # The registry copy with its first data row rewritten by the block.
  def mutate_first_row(text)
    lines = text.lines
    index = first_row_index(lines)
    raise 'the brief has no registry row to mutate' if index.nil?

    row = cells(lines[index])
    yield(row)
    lines[index] = "| #{row.join(' | ')} |\n"
    lines.join
  end

  # The registry copy with its first data row removed.
  def drop_first_row(text)
    lines = text.lines
    index = first_row_index(lines)
    raise 'the brief has no registry row to mutate' if index.nil?

    lines.delete_at(index)
    lines.join
  end

  # The registry copy with its first data row repeated.
  def duplicate_first_row(text)
    lines = text.lines
    index = first_row_index(lines)
    raise 'the brief has no registry row to mutate' if index.nil?

    lines.insert(index + 1, lines[index])
    lines.join
  end

  # Where the registry's first data row sits, after the table's header.
  def first_row_index(lines)
    header = lines.index { |line| cells(line) == TABLE_HEADER }
    raise 'the brief has no registry table' if header.nil?

    ((header + 1)...lines.size).find { |at| data_row?(lines[at]) }
  end

  def normalize(text)
    text.gsub(/\s+/, ' ').strip
  end
end
