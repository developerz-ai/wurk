# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../tasks/llms_full'

# The public surfaces outside docs/wiki/ (which wiki_pages_test.rb gates) that
# a reader or an agent treats as the project's pitch: README, the docs site,
# the llms.txt map and its generated full dump, and the gem's own summary.
# CLAUDE.md pillar 3 forbids a "faster" claim on any of them until
# docs/benchmarks.md supports it; the shipped dashboard has no per-job progress
# surface (status is machine-only, read through Wurk::Status and the /v1 jobs
# endpoint), so that claim is pinned out here too — a rule nothing reads only
# holds until the next copy edit. The docs site also advertises the dashboard's
# panes, so the inventory it lists is checked against the frontend's own pane
# inventory and the two cannot drift. Reads files and touches no Redis or
# shared state.
class ForbiddenClaimsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)

  FILES = %w[README.md docs/site/llms.txt docs/site/index.html].freeze

  # Wurk is 0.87x-1.02x against stock Sidekiq (docs/benchmarks.md). The honest
  # sentence "Wurk is not currently faster than stock Sidekiq" has to survive,
  # so a sentence is only a claim when nothing in it negates the word. Questions
  # and quoted mentions ('"Faster" is meaningless…') are talk about the claim,
  # not the claim.
  SPEED_CLAIM = /\bfaster\b/i
  # A negation must govern each "faster" itself (within two words before it):
  # "not only free but faster" is still a claim.
  NEGATED_PREFIX = /\b(?:not|no|never|isn't|aren't|nor)\W+(?:\w+\W+){0,2}\z/i

  # No production throughput numbers are published (audit R11). Reintroduce a
  # scale figure only together with the soak numbers in docs/benchmarks.md, and
  # update this guard in the same change.
  SCALE_CLAIM = /millions of jobs|jobs an hour/i

  # Status readers are machine-only. Match reader promises locally, not mere
  # dashboard/status co-occurrence: the full docs legitimately discuss both.
  DASHBOARD_READER_CLAIM = /
    per-job\s+progress |
    read\s+back\s+from\s+Ruby\s+or\s+(?:the\s+)?dashboard |
    \bdashboard\s+(?:shows?|displays?|reads?|provides?)\s+(?:the\s+)?
      (?:job[-\s]+)?(?:status|results?)\b |
    \bjob[-\s]+(?:status|results?)(?:\s+and\s+results?)?\s+
      (?:in|on|through|from|via)\s+(?:the\s+)?dashboard\b
  /ix

  def test_no_public_surface_claims_wurk_is_faster
    offenders = surfaces.flat_map do |name, text|
      sentences(text).filter_map do |sentence|
        "#{name}: #{sentence[0, 160]}" if speed_claim?(sentence)
      end
    end

    assert_empty offenders,
                 'Wurk is 0.87x-1.02x against stock Sidekiq, so no public surface may claim it is ' \
                 "faster (CLAUDE.md pillar 3, docs/benchmarks.md):\n#{offenders.join("\n")}"
  end

  def test_no_public_surface_claims_an_unpublished_scale_figure
    offenders = surfaces.filter_map { |name, text| name if text.match?(SCALE_CLAIM) }

    assert_empty offenders,
                 'no production throughput numbers are published; drop the scale claim or publish ' \
                 "the numbers in docs/benchmarks.md first: #{offenders.join(', ')}"
  end

  def test_no_public_surface_claims_a_job_status_reader_dashboard
    assert_no_dashboard_reader_claims
  end

  def test_dashboard_guard_rejects_reader_promises_in_each_pitch_surface
    claims = [
      'the dashboard shows a per-job progress bar',
      'read back from Ruby or the dashboard',
      'The dashboard shows job status.',
      'The dashboard displays job results.',
      'The dashboard provides status and results.',
      'Read job-status through the dashboard.',
      'Read job results in the dashboard.',
      '<p>Read job <strong>results</strong> from the dashboard.</p>',
      "Read back from Ruby or\n the dashboard."
    ]

    FILES.each do |path|
      claims.each do |claim|
        injected = surfaces.merge(path => "#{surfaces.fetch(path)}\n#{claim}")

        assert_raises(Minitest::Assertion, "#{path} must reject #{claim.inspect}") do
          assert_no_dashboard_reader_claims(injected)
        end
      end
    end
  end

  def test_dashboard_guard_accepts_machine_readers_in_each_pitch_surface
    accurate = [
      'Read job status and results from Ruby through Wurk::Status / record.to_h.',
      'Read job status over the bearer-scoped /v1 HTTP API (GET /jobs/:jid).',
      'Opt-in <code>track: true</code> persists state, coalesced progress writes, and the return value ' \
      '&mdash; read back from Ruby or over the bearer-scoped <code>/v1</code> HTTP API ' \
      '(<code>GET /jobs/:jid</code>).',
      'The dashboard shows queues. Read job status and results through Wurk::Status.',
      'Job status and results use the HTTP API. The dashboard has click-through job detail.'
    ]

    FILES.each do |path|
      accurate.each do |copy|
        assert_no_dashboard_reader_claims(surfaces.merge(path => "#{surfaces.fetch(path)}\n#{copy}"))
      end
    end
  end

  def test_site_attributes_parity_to_independently_written_oracles
    site = read_doc('docs/site/index.html').gsub(/\s+/, ' ')
    why = site[%r{<section id="why".*?</section>}]

    refute_nil why, 'the site must retain its Why section'
    assert_includes why, 'independently written oracles for documented Sidekiq behavior'
    refute_match(/Sidekiq['’]s own tests/i, site)
  end

  def test_the_guard_still_catches_a_bare_claim
    assert speed_claim?('Faster.'), 'the wiki once shipped "Free forever. Faster."'
    assert speed_claim?('Faster than stock Sidekiq')
    refute speed_claim?('Wurk is not currently faster than stock Sidekiq')
    assert speed_claim?('Wurk is not only free but faster than Sidekiq')
    assert speed_claim?('Wurk is not faster than Sidekiq, but it is faster than Resque')
  end

  PANE_INVENTORIES = %w[feature-panes dashboard-panes].freeze

  # Where the frontend declares its shipped panes. main keeps the inventory in
  # navPanes.json ("the one inventory in the repo", read by Nav.tsx and by the
  # frontend's own drift check); the tree this guard was cut on still declared
  # the same panes inline in Nav.tsx.
  PANE_INVENTORY_JSON = 'frontend/src/navPanes.json'
  PANE_INVENTORY_INLINE = 'frontend/src/components/Nav.tsx'

  def test_both_site_inventories_match_shipped_dashboard_panes
    panes = shipped_panes
    site = File.read(File.join(ROOT, 'docs/site/index.html'))

    PANE_INVENTORIES.each { |id| assert_inventory(site, id, panes) }
  end

  def test_inventory_guard_rejects_every_omission_including_flows_profiles_and_search
    panes = shipped_panes
    panes.each do |pane|
      PANE_INVENTORIES.each do |id|
        incomplete = inventory_markup(id, panes - [pane])
        assert_raises(Minitest::Assertion, "#{id} must reject missing #{pane}") do
          assert_inventory(incomplete, id, panes)
        end
      end
    end
  end

  def test_inventory_guard_rejects_extras_duplicates_empty_and_missing_markers
    panes = shipped_panes
    PANE_INVENTORIES.each do |id|
      [panes + ['Unshipped pane'], panes + [panes.first], []].each do |invalid|
        assert_raises(Minitest::Assertion) { assert_inventory(inventory_markup(id, invalid), id, panes) }
      end
      ['', panes.join(', '), "<span>#{panes.join(', ')}</span>"].each do |unmarked|
        assert_raises(Minitest::Assertion) { assert_inventory(unmarked, id, panes) }
      end
      duplicate = inventory_markup(id, panes) * 2
      assert_raises(Minitest::Assertion) { assert_inventory(duplicate, id, panes) }
      assert_raises(Minitest::Assertion) { assert_inventory(inventory_markup(id, panes), id, []) }
    end
  end

  def test_shipped_pane_extraction_rejects_empty_or_unrecognized_navigation
    labels = { 'dashboard' => 'Dashboard' }
    routes = '<Route path="/" />'

    ['', 'const LINKS = [];', 'const LINKS = [{ destination: "/" }];'].each do |nav|
      assert_raises(Minitest::Assertion) { extract_panes(inline_panes(nav), labels, routes) }
    end
    ['[]', '{}', '[{ "destination": "/" }]'].each do |inventory|
      assert_raises(Minitest::Assertion) { extract_panes(json_panes(inventory), labels, routes) }
    end

    panes = inline_panes("const LINKS = [{ to: '/', label: t('nav.dashboard') }];")

    assert_raises(Minitest::Assertion) { extract_panes(panes, labels, '') }
    assert_raises(Minitest::Assertion) { extract_panes(panes, {}, routes) }
  end

  MEASUREMENTS = 'docs/plans/2026/08/06/101-faster-than-sidekiq/08-measurements.md'
  HEADLINES = %w[
    README.md docs/site/llms.txt docs/wiki/Home.md docs/wiki/Performance.md CLAUDE.md
    docs/idea/00-seed.md docs/idea/01-overview.md docs/idea/06-performance.md docs/idea/13-roadmap.md
  ].freeze
  RATIO_RANGE = /(?<![\d.])(\d+\.\d+)[x×]\s*[–-]\s*(\d+\.\d+)[x×]/
  RELEASE_COMPARISON = /(?:every release[^.!?]*(?:benchmark|Sidekiq)|(?:benchmark|Sidekiq)[^.!?]*every release)/i
  RANGE_CANDIDATE = /(?:\d+\.\d+[x×]\s*[–-]\s*\S+|\S+\s*[–-]\s*\d+\.\d+[x×])/

  def test_published_tables_and_engine_labels_match_raw_paired_evidence
    evidence = measurement_evidence(read_doc(MEASUREMENTS))
    %w[docs/benchmarks.md docs/wiki/Performance.md].each do |path|
      text = read_doc(path)

      assert_equal evidence.fetch(:rows).map { |row| row.drop(1) }, published_rows(text), path
    end
    %w[README.md docs/benchmarks.md docs/wiki/Performance.md].each do |path|
      assert_engine_labels(read_doc(path), evidence)
    end
    assert_operator read_doc('docs/wiki/Performance.md').lines.size, :<=, 70
  end

  def test_headline_ranges_follow_paired_medians_not_pooled_ratios
    evidence = measurement_evidence(read_doc(MEASUREMENTS))

    HEADLINES.each { |path| assert_headline_range(read_doc(path), evidence, path) }
    assert_headline_range(WurkDocs::LlmsFull.build(ROOT), evidence, 'llms-full build output')
  end

  def test_guide_headline_and_summary_remain_dated
    text = read_doc('docs/benchmarks.md')

    assert_guide_summary(text)
    ['currently faster', 'current-release guarantee'].each do |phrase|
      bad = text.sub('historical measurements', phrase)
      assert_raises(Minitest::Assertion) { assert_guide_summary(bad) }
    end
  end

  def test_command_builder_measurement_is_attributed_to_release_notes
    guide = read_doc('docs/benchmarks.md')

    assert_command_builder_attribution(guide)
    ['~2.1µs', '~0.48µs', 'historical measurement', '../CHANGELOG.md#170---2026-08-10'].each do |token|
      assert_raises(Minitest::Assertion) { assert_command_builder_attribution(guide.gsub(token, 'drift')) }
    end
  end

  def test_no_every_release_comparison_promise
    surfaces.each do |name, text|
      refute_match(RELEASE_COMPARISON, text,
                   "#{name}: must not promise comparison benchmarking every release")
    end
  end

  def test_range_guard_rejects_drift_and_malformed_claims_even_beside_correct_range
    evidence = measurement_evidence(read_doc(MEASUREMENTS))
    %w[x ×].each do |sign|
      good = "Wurk vs stock Sidekiq: 0.87#{sign}–1.02#{sign}."

      assert_headline_range(good, evidence, 'synthetic')
      [good.sub('0.87', '0.86'), good.sub('1.02', '1.03'), 'No numerical claim.',
       good.sub('1.02', 'unknown')].each do |bad|
        assert_raises(Minitest::Assertion) { assert_headline_range(bad, evidence, 'synthetic') }
        next if bad == 'No numerical claim.'

        assert_raises(Minitest::Assertion) { assert_headline_range("#{good}\n\n#{bad}", evidence, 'mixed') }
      end
      historical = "Historically Wurk vs Sidekiq: 0.45#{sign}–0.86#{sign}.\n\n#{good}"

      assert_headline_range(historical, evidence, 'historical figures are allowed')
    end
  end

  def test_measurement_guards_reject_drift_missing_and_malformed_evidence
    raw = read_doc(MEASUREMENTS)
    evidence = measurement_evidence(raw)
    good = 'wurk 1.4.0 vs sidekiq 8.1.6, measured 2026-08-07'

    assert_engine_labels(good, evidence)
    [good.sub('1.4.0', '1.5.0'), good.sub('8.1.6', '8.1.7'), '', good.sub('2026-08-07', 'today')].each do |bad|
      assert_raises(Minitest::Assertion) { assert_engine_labels(bad, evidence) }
    end
    ['', raw.sub('**0.87×**', '**unknown**'), raw.sub('wurk 1.4.0 vs', 'wurk unknown vs'),
     raw.sub('| Date | 2026-08-07 |', ''),
     raw.sub('| 4p × 5t | io | **0.97×** | 0.60× | 1.26× |', '')].each do |bad|
      assert_raises(Minitest::Assertion) { measurement_evidence(bad) }
    end
    ['Every release benchmarked against stock Sidekiq', 'against stock Sidekiq every release'].each do |bad|
      assert_match RELEASE_COMPARISON, bad
    end
    rows = published_rows(read_doc('docs/benchmarks.md'))
    drifted = rows.map { |row| row.map { |value| value == '0.87' ? '0.86' : value } }

    refute_equal evidence.fetch(:rows).map { |row| row.drop(1) }, drifted
  end

  private

  def assert_no_dashboard_reader_claims(pitch_surfaces = surfaces)
    offenders = pitch_surfaces.filter_map do |name, text|
      prose = text.gsub(/<[^>]+>/, ' ').gsub(/\s+/, ' ')
      name if prose.match?(DASHBOARD_READER_CLAIM)
    end

    assert_empty offenders,
                 'the shipped dashboard has no per-job progress or status/results reader; name the machine readers ' \
                 "(Wurk::Status, /v1 GET /jobs/:jid) instead: #{offenders.join(', ')}"
  end

  def read_doc(path)
    File.read(File.join(ROOT, path))
  end

  def measurement_evidence(raw)
    engines = raw.match(/^\| Engines \| wurk (\d+\.\d+\.\d+) vs sidekiq (\d+\.\d+\.\d+) \|$/)
    date = raw[/^\| Date \| (\d{4}-\d{2}-\d{2}) \|$/, 1]

    refute_nil engines, 'raw measurement engine versions must be extractable'
    refute_nil date, 'raw measurement date must be extractable'
    paired = raw[/^### Paired per-run ratios[^\n]*\n(.*?)(?=^Boot to first job)/m, 1]

    refute_nil paired, 'raw paired estimator section must exist (not the pooled table)'
    rows = paired.lines.grep(/^\| [14]p /).map do |line|
      cells = line.delete('*').split('|').map(&:strip)[1...-1]

      assert_equal 5, cells.size, "malformed paired row: #{line}"
      assert_includes ['1p × 5t', '4p × 5t'], cells[0]
      assert_includes %w[noop cpu io], cells[1]
      cells.drop(2).each { |value| assert_match(/\A\d+\.\d+[x×]\z/, value) }
      cells.map { |value| value.sub(/[x×]\z/, '') }
    end

    assert_equal ['1p × 5t', '4p × 5t'].product(%w[noop cpu io]), rows.map { |row| row.take(2) },
                 'raw paired table must contain all six topology/workload rows in publication order'
    medians = rows.map { |row| Float(row[2]) }
    { engines: engines.captures, date: date, rows: rows, range: medians.minmax }
  end

  def published_rows(text)
    text.lines.grep(/^\| (?:noop|cpu|io) \|/).map do |line|
      cells = line.split('|').map(&:strip)[1...-1]

      assert_equal 4, cells.size, "malformed published row: #{line}"
      cells.drop(1).each { |value| assert_match(/\A\d+\.\d+[x×]\z/, value) }
      cells.map { |value| value.sub(/[x×]\z/, '') }
    end
  end

  def assert_engine_labels(text, evidence)
    versions = text.scan(/\b(wurk|sidekiq) (\d+\.\d+\.\d+)/i).map { |engine, version| [engine.downcase, version] }

    %w[wurk sidekiq].zip(evidence.fetch(:engines)).each do |engine, version|
      assert_equal [version], versions.select { |name, _| name == engine }.map(&:last).uniq,
                   "published #{engine} label must match the raw measurement, not today's gem"
    end
    assert_includes text, evidence.fetch(:date)
    dates = text.scan(/\bmeasured (\d{4}-\d{2}-\d{2})/i).flatten.uniq

    assert_equal [evidence.fetch(:date)], dates
  end

  def assert_headline_range(text, evidence, name)
    prose = text.gsub(/\]\([^)]*\)/, ']')
    claims = prose.split(/\n\s*\n/).select do |paragraph|
      paragraph.match?(/Sidekiq/i) && !paragraph.match?(/\A\s*(?:Historically|Previously)\b/i) &&
        paragraph.match?(RANGE_CANDIDATE)
    end

    refute_empty claims, "#{name}: missing or malformed paired headline range"
    claims.each do |claim|
      candidates = claim.scan(RANGE_CANDIDATE)
      ranges = claim.scan(RATIO_RANGE)

      assert_equal candidates.size, ranges.size, "#{name}: malformed paired headline range"
      ranges.each do |low, high|
        assert_equal evidence.fetch(:range), [Float(low), Float(high)], "#{name}: drifted paired headline range"
      end
    end
  end

  def assert_guide_summary(text)
    headline = text.lines[2]

    assert_includes headline, 'latest published paired comparison (2026-08-07)'
    assert_includes headline, 'historical measurements, not a current-release guarantee'
    refute_match(/currently|today/i, headline)
    summary = text.lines.find { |line| line.start_with?('**Published result') }

    refute_nil summary
    assert_includes summary, '(2026-08-07)'
    assert_includes summary, 'was at parity'
    assert_includes summary, 'still behind on `noop` and on boot'
  end

  def assert_command_builder_attribution(text)
    notes = read_doc('CHANGELOG.md').lines.find { |line| line.start_with?('- **`Wurk::CommandBuilder`') }

    refute_nil notes
    timing = notes[/~[\d.]+µs → ~[\d.]+µs per command/]

    refute_nil timing
    paragraph = text[/The \[1\.7\.0 release notes\].*?timing run here\./m]

    refute_nil paragraph
    assert_includes paragraph, '../CHANGELOG.md#170---2026-08-10'
    assert_includes paragraph, timing
    assert_includes paragraph, 'historical measurement, not a new'
  end

  def shipped_panes
    labels = JSON.parse(File.read(File.join(ROOT, 'frontend/src/i18n/en.json'))).fetch('nav')
    routes = File.read(File.join(ROOT, 'frontend/src/App.tsx'))
    extract_panes(pane_inventory, labels, routes)
  end

  # [path, nav label key] per shipped pane, in rail order. The panes live in
  # one inventory, but that inventory moved: main keeps it in navPanes.json and
  # derives Nav.tsx's LINKS from it, while the tree this guard was cut on
  # declared the same panes inline in Nav.tsx. Read whichever the tree ships,
  # and fail loudly when neither declares a pane — a guard that stops reading
  # its source stops guarding.
  def pane_inventory
    json = File.join(ROOT, PANE_INVENTORY_JSON)

    return json_panes(File.read(json)) if File.exist?(json)

    inline_panes(File.read(File.join(ROOT, PANE_INVENTORY_INLINE)))
  end

  # main's inventory: [{ "to": "/queues", "labelKey": "nav.queues", ... }].
  def json_panes(source)
    panes = JSON.parse(source)

    assert_kind_of Array, panes, "#{PANE_INVENTORY_JSON} must hold an array of panes"
    refute_empty panes, "#{PANE_INVENTORY_JSON} must contain built-in panes"
    panes.map { |pane| json_pane(pane) }
  end

  def json_pane(pane)
    assert_kind_of Hash, pane, "unrecognized pane: #{pane.inspect}"
    to = pane['to']
    key = pane['labelKey']

    assert(to.is_a?(String) && key.is_a?(String), "unrecognized pane: #{pane.inspect}")
    [to, key.delete_prefix('nav.')]
  end

  # The inline shape: Nav.tsx's `const LINKS = [...]` array of panes.
  def inline_panes(source)
    links = source[/\bconst LINKS\s*=\s*\[(.*?)\];/m, 1]

    refute_nil links, "#{PANE_INVENTORY_INLINE} LINKS must be extractable"
    entries = links.scan(/\{[^{}]*\}/)

    refute_empty entries, "#{PANE_INVENTORY_INLINE} LINKS must contain built-in panes"
    entries.map { |entry| inline_pane(entry) }
  end

  def inline_pane(entry)
    match = entry.match(/to:\s*'([^']+)',\s*label:\s*t\('nav\.([^']+)'\)/)

    refute_nil match, "unrecognized LINKS entry: #{entry}"
    match.captures
  end

  def extract_panes(inventory, labels, app)
    routes = app.scan(/<Route\s+path="([^"]+)"/).flatten

    refute_empty routes, 'App.tsx routes must be extractable'
    panes = inventory.map do |path, key|
      assert_includes routes, path, "built-in pane #{key} must have an App route"
      label = labels[key]

      assert_kind_of String, label, "missing English nav label: #{key}"
      refute_empty label.strip, "empty English nav label: #{key}"
      label
    end

    assert_equal panes.uniq, panes, 'built-in pane labels must be unique'
    panes
  end

  def inventory_markup(marker, panes)
    "<span id=\"#{marker}\">#{panes.join(', ')}</span>"
  end

  def assert_inventory(site, marker, panes)
    refute_empty panes, 'expected panes must not be empty'
    inventories = site.scan(%r{<span\s+id="#{Regexp.escape(marker)}"\s*>([^<]*)</span>}m).flatten

    assert_equal 1, inventories.length, "expected exactly one marked inventory: #{marker}"
    actual = inventories.first.split(',').map(&:strip)

    refute_empty actual, "#{marker} must not be empty"
    assert_equal actual.uniq, actual, "#{marker} must not duplicate panes"
    assert_equal panes.sort, actual.sort, "#{marker} must list exactly the shipped pane names"
  end

  def surfaces
    @surfaces ||= FILES.to_h { |rel| [rel, File.read(File.join(ROOT, rel))] }.merge(
      'docs/site/llms-full.txt (generated)' => WurkDocs::LlmsFull.build(ROOT),
      'wurk.gemspec summary/description' => gemspec_pitch
    )
  end

  def gemspec_pitch
    spec = Gem::Specification.load(File.join(ROOT, 'wurk.gemspec'))
    "#{spec.summary}\n#{spec.description}"
  end

  # Link targets and code spans carry paths like plans/…/101-faster-than-sidekiq,
  # which are file names, not prose; HTML tags are markup, not prose.
  def sentences(text)
    text.gsub(/\]\([^)]*\)/, ']').gsub(/`[^`]*`/, '').gsub(/<[^>]+>/, ' ')
        .split(/(?<=[.!?])\s+|\n/)
  end

  def speed_claim?(sentence)
    return false unless sentence.match?(SPEED_CLAIM)
    return false if sentence.rstrip.end_with?('?')

    unquoted = sentence.gsub(/["“][^"”]*["”]/, '')
    unquoted.to_enum(:scan, SPEED_CLAIM).any? { !Regexp.last_match.pre_match.match?(NEGATED_PREFIX) }
  end
end
