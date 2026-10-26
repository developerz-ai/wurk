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

  # The shipped dashboard has no per-job progress surface: status is read
  # through Wurk::Status / record.to_h and the bearer-scoped /v1 jobs endpoint.
  # A dashboard progress claim is always wrong; name the machine reader instead.
  DASHBOARD_PROGRESS_CLAIM = /per-job progress/i

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

  def test_no_public_surface_claims_a_per_job_progress_dashboard
    offenders = surfaces.filter_map { |name, text| name if text.match?(DASHBOARD_PROGRESS_CLAIM) }

    assert_empty offenders,
                 'the shipped dashboard has no per-job progress surface; name the machine readers ' \
                 "(Wurk::Status, /v1 GET /jobs/:jid) instead: #{offenders.join(', ')}"
  end

  def test_the_guard_still_catches_a_bare_claim
    assert speed_claim?('Faster.'), 'the wiki once shipped "Free forever. Faster."'
    assert speed_claim?('Faster than stock Sidekiq')
    refute speed_claim?('Wurk is not currently faster than stock Sidekiq')
    assert speed_claim?('Wurk is not only free but faster than Sidekiq')
    assert speed_claim?('Wurk is not faster than Sidekiq, but it is faster than Resque')
    assert_match DASHBOARD_PROGRESS_CLAIM, 'the dashboard shows a per-job progress bar',
                 'the dashboard per-job-progress phrasing must stay guarded'
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

  private

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
