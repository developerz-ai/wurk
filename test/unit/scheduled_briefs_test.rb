# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# Gates the docs-drift checkup brief (.dz/schedules/docs-drift.md): the registry
# of documented surfaces and the guards that cover them.
#
# The failure this exists to catch is a registry that overstates its own
# coverage. An inventory-backed check — llms-full's docs/*.md inventory, the
# conformance cases' promise-to-oracle bindings — proves MEMBERSHIP: every
# top-level doc is inlined verbatim or explicitly excluded, every sourced
# promise is registered against a runnable oracle. It proves nothing about the
# prose those surfaces enumerate — bar the two sentences llms-full pins by
# name — and nothing in the repo compares the llms.txt map with the llms-full
# inventory. A brief claiming either is a guard that cannot fail, so the
# ownership wording is pinned here: delete it from the brief and this file
# goes red.
#
# The brief's own claims are pinned too: no docs-drift schedule is registered
# in the policy, so the brief must say that nothing fires it.
#
# Reads files only. Touches no Redis and no shared state.
class ScheduledBriefsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  BRIEF = File.join(ROOT, '.dz', 'schedules', 'docs-drift.md')
  BRIEF_REL = '.dz/schedules/docs-drift.md'
  POLICY = File.join(ROOT, '.dz', 'maintainer', 'maintainer.yml')

  # The docs-drift brief is read by an unattended lane: past this size it stops
  # being a brief and becomes a document nobody reads to the end.
  SIZE_CAP = 8192

  # A read-only checkup runs no command that writes. The prose may name these
  # tools while promising never to run them; the commands may not contain them.
  WRITE_COMMANDS = /
    \brm\s+-[a-zA-Z]*[rf]
    | git\s+(commit|push|rm|checkout|reset|apply)\b
    | sed\s+-i
    | gh\s+(pr|issue)\s+create
  /x

  def setup
    @text = File.file?(BRIEF) ? File.read(BRIEF) : ''
    @normalized = normalize(@text)
    @rows = registry_rows
  end

  def test_the_brief_exists_and_stays_within_its_size_cap
    assert File.file?(BRIEF), "#{BRIEF_REL} must exist: the docs-drift schedule reads it"
    assert_operator File.size(BRIEF), :<=, SIZE_CAP,
                    "#{BRIEF_REL} must stay under #{SIZE_CAP} bytes — an unattended lane reads it"
  end

  def test_every_registered_schedule_points_at_a_brief_that_exists
    schedules = policy.fetch('schedules', [])

    refute_empty schedules, 'the maintainer policy must register at least one schedule'

    schedules.each do |schedule|
      brief_file = schedule['brief_file']

      refute_nil brief_file, "schedule #{schedule['name']} must name a brief_file"
      assert File.file?(File.join(ROOT, brief_file)),
             "schedule #{schedule['name']} points at #{brief_file}, which does not exist"
    end
  end

  def test_the_docs_drift_schedule_reads_this_brief
    schedules = policy.fetch('schedules', [])
    docs_drift = schedules.find { |schedule| schedule['name'] == 'docs-drift' }

    if docs_drift
      assert_equal BRIEF_REL, docs_drift['brief_file'],
                   'the docs-drift schedule must read .dz/schedules/docs-drift.md'
    else
      assert File.file?(BRIEF),
             "#{BRIEF_REL} must exist so a docs-drift schedule can point at it"
    end
  end

  # Nothing fires the brief today: the policy registers no docs-drift
  # schedule, so the brief must say so instead of claiming one reads it.
  def test_the_brief_does_not_claim_a_docs_drift_schedule_the_policy_does_not_carry
    schedules = policy.fetch('schedules', [])
    docs_drift = schedules.find { |schedule| schedule['name'] == 'docs-drift' }

    if docs_drift
      assert_equal BRIEF_REL, docs_drift['brief_file'],
                   'a registered docs-drift schedule must read .dz/schedules/docs-drift.md'
      refute_match(/no docs-drift schedule is registered/i, @normalized,
                   'the policy registers a docs-drift schedule: the brief must not deny it')
    else
      assert_match(/no docs-drift schedule is registered/i, @normalized,
                   'the brief must say the policy registers no docs-drift schedule')
      assert_match(/nothing fires this brief until/i, @normalized,
                   'the brief must say nothing fires it until a schedule is registered')
    end

    schedules.each do |schedule|
      assert_includes @normalized, schedule['name'],
                      "the brief must name the schedules the policy registers (#{schedule['name']})"
    end

    claiming = sentences(@text).select do |sentence|
      sentence.include?('docs-drift') &&
        sentence.match?(/schedule reads|schedule is registered|schedule fires|schedule points|schedule runs/i) &&
        !sentence.match?(/\b(?:no|not|nothing|never|until|unregistered|without)\b/i)
    end

    assert_empty claiming,
                 "the brief must not claim a registered docs-drift schedule: #{claiming.join(' ')}"
  end

  def test_the_brief_is_read_only
    assert_match(/read-only/i, @normalized, 'the brief must say the lane is read-only')
    assert_match(/never edits a file/i, @normalized, 'the brief must say it never edits a file')
    assert_match(/files nothing/i, @normalized, 'the brief must say it files nothing')

    blocks = @text.scan(/```bash\n(.*?)```/m).flatten

    refute_empty blocks, 'the brief must show how the tree is read'
    blocks.each do |block|
      refute_match WRITE_COMMANDS, block, 'the read-only brief must carry no command that writes'
    end
  end

  def test_an_inventory_backed_check_guards_membership_not_prose
    assert_match(/inventory-backed check is a guard for membership, not for the prose it enumerates/i,
                 @normalized,
                 'the brief must scope an inventory-backed check to membership, not to the prose it enumerates')
  end

  def test_llms_full_is_registered_for_membership_only
    row = row_for(%r{\Adocs/\*\.md\z})

    refute_nil row, 'the registry must list the docs/*.md surface'
    assert_includes row[1], 'test/unit/llms_full_test.rb'
    assert_match(/membership/i, row[2], 'the llms-full guard protects inventory membership')
    assert_match(/verbatim/i, row[2], 'the llms-full guard protects the verbatim inlining')
    assert_scoped_to_shape(row[2])
  end

  # The llms-full guard is scoped to membership, but it does pin two content
  # anchors: the row must name them rather than claim silence about the prose
  # it inlines.
  def test_llms_full_row_names_the_two_content_anchors_it_pins
    row = row_for(%r{\Adocs/\*\.md\z})

    refute_nil row, 'the registry must list the docs/*.md surface'
    assert_includes row[2], 'sidekiq-cron entries: 3 (2 importable, 1 skipped)',
                    'the llms-full row must name the migration-guide content anchor'
    assert_includes row[2], "so you never dispatch a job whose row hasn't landed.",
                    'the llms-full row must name the active-job guide content anchor'
    assert_includes @text, 'test/unit/llms_full_test.rb:104-108',
                    'the brief must point at the llms-full content-anchor assertions'
    refute_match(/says nothing about/i, @normalized,
                 'the brief must not claim the llms-full guard says nothing about the prose')
  end

  def test_conformance_is_registered_for_registration_only
    row = row_for(%r{\Adocs/target/})

    refute_nil row, 'the registry must list the parity-spec promises'
    assert_includes row[1], 'test/unit/conformance_test.rb'
    assert_match(/registration/i, row[2], 'the conformance guard protects promise-to-oracle registration')
    assert_match(/oracle/i, row[2], 'the conformance guard protects the oracle binding')
    assert_scoped_to_shape(row[2])
  end

  # The oracle binding is checked where the conformance suite runs; the unit
  # test covers the inventory's machinery. The row must name both.
  def test_conformance_row_names_the_oracle_binding_check_beside_the_unit_check
    row = row_for(%r{\Adocs/target/})

    refute_nil row, 'the registry must list the parity-spec promises'
    assert_includes row[1], 'test/unit/conformance_test.rb',
                    'the conformance row must name the inventory machinery check'
    assert_includes row[1], 'test/conformance/conformance_test.rb',
                    'the conformance row must name the check that binds the oracles'
  end

  def test_no_registry_entry_claims_the_map_is_checked_against_the_inventory
    offending = @rows.select do |row|
      joined = row.join(' ')

      joined.match?(/inventory/i) && joined.match?(/llms\.txt|\bmap\b/i)
    end

    assert_empty offending,
                 'no registry row may claim a check compares the llms.txt map with the llms-full inventory'

    relations = section('Relations no check covers')

    assert_match(/nothing compares/i, relations,
                 'the brief must say the map-versus-inventory relation is covered by nothing')
    assert_includes relations, 'llms.txt'
    assert_includes relations, 'inventory'
  end

  def test_contributing_is_listed_with_its_narrow_guard
    row = row_for(/\ACONTRIBUTING\.md\z/)

    refute_nil row, 'CONTRIBUTING.md must be in the surfaces list'
    assert_includes row[1], 'test/unit/contributing_line_refs_test.rb'
    assert_match(%r{bin/check}i, row[2], 'the guard protects the bin/check line references')
    assert_match(/line reference/i, row[2], 'the guard protects the line references and nothing else')
    assert_match(/only/i, row[2], 'the guard protects the line references only')
  end

  def test_the_python_readme_is_listed_as_unguarded_without_a_stale_claim
    row = row_for(%r{\Aclients/python/README\.md\z})

    refute_nil row, 'clients/python/README.md must be in the surfaces list'
    assert_match(/none/i, row[1], 'the Python README has no guard')
    assert_match(/no test/i, row[2], 'the cell must say no test reads it')
    assert_match(%r{bin/check}i, row[2], 'the cell must say the file never mentions bin/check')

    lines = @text.lines.select { |line| line.include?('clients/python/README.md') }
    stale = lines.grep(/stale/i)

    assert_empty stale,
                 "the brief must not call the Python README's silence about bin/check stale: #{stale.join(' ')}"
  end

  def test_the_brief_states_what_it_excludes
    scope = section('Out of scope')

    refute_empty scope.strip, 'the brief must state what it excludes'
    assert_match(/nested/i, scope, 'the exclusion must name the nested docs')
    assert_match(/generated/i, scope, 'the exclusion must name the generated output')
  end

  def test_each_finding_is_reported_once
    reporting = section('Reporting')

    assert_match(/one finding per surface/i, reporting, 'a finding is keyed by its surface and guard')
    assert_match(/never the same finding twice/i, reporting, 'the same finding is never reported twice')
  end

  def test_every_check_the_brief_names_exists
    paths = @text.scan(%r{\b(?:test|tasks)/[\w./-]+\.(?:rb|yml)\b}).uniq

    refute_empty paths, 'the brief names the checks that guard its surfaces'
    missing = paths.reject { |path| File.file?(File.join(ROOT, path)) }

    assert_empty missing, "the brief names checks that do not exist: #{missing.join(', ')}"
  end

  private

  def policy
    @policy ||= YAML.safe_load_file(POLICY, aliases: false)
  end

  def normalize(text)
    text.gsub(/[*`]/, '').gsub(/\s+/, ' ').strip
  end

  # The body of one `##` section, up to the next one.
  def section(name)
    lines = @text.lines
    start = lines.index { |line| line.start_with?('#') && line.include?(name) }

    return '' unless start

    rest = lines[(start + 1)..]
    stop = rest.index { |line| line.start_with?('## ') }
    (stop ? rest[0...stop] : rest).join
  end

  # The brief's sentences: a claim about the docs-drift schedule is read whole,
  # so a negation elsewhere in the same sentence counts.
  def sentences(text)
    text.split(/(?<=[.!?])\s+/)
  end

  # The registry table's rows: [surface, guard, what it protects].
  def registry_rows
    rows = section('Surfaces and their guards').lines.filter_map do |line|
      next unless line.start_with?('|')

      cells = line.split('|', -1)[1..-2].map { |cell| cell.strip.delete('`') }
      next unless cells.size == 3

      cells
    end

    rows.reject { |cells| cells.first.match?(/\A:?-{2,}\z/) }.drop(1)
  end

  def row_for(pattern)
    @rows.find { |row| pattern.match?(row[0]) }
  end

  # A guard cell must name the one claim it protects and say what it does not.
  def assert_scoped_to_shape(cell)
    assert_match(/only/i, cell, 'the cell must scope the guard to a single claim')
    assert_match(/not the truth of the /i, cell,
                 'the cell must say the guard does not cover the prose it enumerates')
  end
end
