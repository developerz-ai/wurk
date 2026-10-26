# frozen_string_literal: true

require 'minitest/autorun'
require 'date'
require 'yaml'

# Pins the three read-only scout schedules the maintainer policy carries.
#
# The policy already ran two checkups (release-due, health); these three are
# scouts: they read the repo and report a finding, and their briefs say so in
# writing. That claim is only worth anything if it is enforced, so this test
# pins every part of it:
#
#   1. The policy still parses as YAML and carries a `schedules:` list.
#   2. Each scout has an entry whose keys are exactly the four the existing
#      entries use (name, days, hours_utc, brief_file) — a key the platform
#      does not read is a promise nothing keeps.
#   3. The three fall on three different weekdays, so two scouts never land on
#      the same day and one lane's findings drown another's.
#   4. Every brief exists, is non-empty and stays inside the size cap.
#   5. Every brief states what a finding must carry (the anchor, what is
#      wrong, how to tell it is fixed), declares the lane read-only, and names
#      the areas it must not touch.
#   6. Every brief dedupes its ask against the open issues, with the same
#      paginated lookup .dz/briefs/health.md uses.
#
# The two committed checkups stay where their own tests pin them
# (test/unit/health_brief_test.rb:69-70, test/unit/release_due_brief_test.rb:18,
# test/unit/release_doc_claims_test.rb:20): this test asserts it, so a future
# re-path fails here instead of in three unrelated gates.
#
# Reads files only; touches no Redis and no shared state.
class ScheduledBriefsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  POLICY = File.join(ROOT, '.dz', 'maintainer', 'maintainer.yml')

  # name => the schedule entry it must have. The brief_file paths are the ones
  # the policy carries; a scout whose brief moved needs the policy and the
  # brief updated together, never one without the other.
  SCOUTS = {
    'coverage-gaps' => {
      'days' => %w[tue],
      'hours_utc' => [8],
      'brief_file' => '.dz/schedules/coverage-gaps.md'
    },
    'docs-drift' => {
      'days' => %w[thu],
      'hours_utc' => [9],
      'brief_file' => '.dz/schedules/docs-drift.md'
    },
    'sidekiq-parity' => {
      'days' => %w[sat],
      'hours_utc' => [10],
      'brief_file' => '.dz/schedules/sidekiq-parity.md'
    }
  }.freeze

  # The key set the two existing entries use — a schedule entry carrying any
  # other key is a key nothing reads.
  SCHEDULE_KEYS = %w[name days hours_utc brief_file].freeze

  # The checkups whose briefs are pinned by three other tests.
  CHECKUP_BRIEFS = {
    'release-due' => '.dz/briefs/release-due.md',
    'health' => '.dz/briefs/health.md'
  }.freeze

  # 8 KB. The platform's own cap is not documented in this repo, so the repo
  # pins one it can check: well under .dz/briefs/health.md, the largest brief
  # the platform already reads here.
  MAX_BRIEF_BYTES = 8192

  # A finding is only actionable with all three.
  FINDING_ELEMENTS = ['path:line', 'What is wrong', 'How to tell it is fixed'].freeze

  # The read-only declaration, in the words the briefs use.
  READ_ONLY_CLAUSES = [
    'reads and reports',
    'never edits a file, commits, pushes, opens a pull request',
    'mutates the repo, its Redis data or CI'
  ].freeze

  # What a scout must not report on: the CI config, the maintainer policy
  # (including the scouts' own directory), and the release tooling.
  OUT_OF_SCOPE = [
    '.github/workflows/**',
    '.dz/**',
    '.dz/maintainer/maintainer.yml',
    'RELEASE.md',
    'lib/wurk/version.rb',
    'tasks/release_helpers.rb',
    'bin/gem-*',
    '.github/workflows/release.yml'
  ].freeze

  # The ask dedupe: the paginated issues lookup, not `gh issue list`.
  DEDUPE_CLAUSE = 'gh api --paginate "repos/developerz-ai/wurk/issues?state=open"'

  def setup
    @policy = YAML.safe_load_file(POLICY, permitted_classes: [Date, Time], aliases: true)
    @schedules = @policy.fetch('schedules')
  end

  def test_policy_parses_and_carries_a_schedules_list
    assert_kind_of Hash, @policy,
                   'the maintainer policy must still parse as YAML'
    assert_kind_of Array, @schedules, 'the policy must carry a `schedules:` list'
  end

  def test_each_scout_has_a_schedule_entry_with_the_expected_keys
    SCOUTS.each do |name, expected|
      entry = schedule_for(name)

      refute_nil entry,
                 "the policy must carry a schedule entry named #{name.inspect}"

      assert_equal SCHEDULE_KEYS.sort, entry.keys.sort,
                   "the #{name.inspect} schedule entry must use only the keys the " \
                   "existing entries use (#{SCHEDULE_KEYS.join(', ')}); got #{entry.keys.inspect}"

      assert_equal expected['days'], entry['days'],
                   "the #{name.inspect} scout must fire on the weekday the brief names"
      assert_equal expected['hours_utc'], entry['hours_utc'],
                   "the #{name.inspect} scout must fire at the hour the brief names"
      assert_equal expected['brief_file'], entry['brief_file'],
                   "the #{name.inspect} scout must point at its committed brief"
    end
  end

  def test_every_scout_brief_lives_under_the_schedules_directory
    SCOUTS.each do |name, expected|
      assert expected['brief_file'].start_with?('.dz/schedules/'),
             "the #{name.inspect} brief must live under .dz/schedules/, got " \
             "#{expected['brief_file'].inspect}"
    end
  end

  def test_the_three_scouts_fall_on_three_different_weekdays
    by_day = Hash.new { |hash, key| hash[key] = [] }

    SCOUTS.each_key do |name|
      schedule_for(name).fetch('days').each { |day| by_day[day] << name }
    end

    clashes = by_day.select { |_day, names| names.size > 1 }

    assert_empty clashes,
                 'the three scouts must fall on three different weekdays, or two of ' \
                 "them fire on the same day and one lane's findings drown another's: " \
                 "#{clashes.inspect}"
  end

  def test_every_scout_brief_exists_and_stays_inside_the_size_cap
    SCOUTS.each do |name, expected|
      path = File.join(ROOT, expected['brief_file'])

      assert File.file?(path),
             "the #{name.inspect} brief must exist at #{expected['brief_file']}"

      size = File.size(path)

      assert_operator size, :>, 0, "the #{name.inspect} brief must not be empty"

      assert_operator size, :<=, MAX_BRIEF_BYTES,
                      "the #{name.inspect} brief must stay within #{MAX_BRIEF_BYTES} bytes " \
                      "(it is #{size})"
    end
  end

  def test_every_brief_states_what_a_finding_must_contain
    each_brief_text do |name, text|
      FINDING_ELEMENTS.each do |element|
        assert_includes text, element,
                        "the #{name.inspect} brief must state that a finding carries " \
                        "#{element.inspect}"
      end
    end
  end

  def test_coverage_brief_permits_frontend_inspection_and_filing_with_stable_titles
    text = File.read(File.join(ROOT, SCOUTS.fetch('coverage-gaps').fetch('brief_file'))).split.join(' ')

    assert_includes text, 'inspection and filing of frontend contract/error-path coverage gaps under `frontend/src/`'
    assert_includes text, 'Inspect frontend source and existing tests, and file concrete contract/error-path gaps'
    assert_includes text, 'One ask per file, never one per gap'
    assert_includes text, "file's path without the line number as the title"
    assert_includes text, 'Coverage gap: lib/wurk/<file>.rb'
    assert_includes text, 'Coverage gap: frontend/src/<file>.ts'
    assert_includes text, 'Coverage gap: frontend/src/components/<file>.tsx'
    assert_includes text, 'The title must not change between runs'
    assert_includes text, 'the dedupe below is an exact title match'
  end

  def test_coverage_brief_requires_actionable_frontend_contract_evidence
    text = File.read(File.join(ROOT, SCOUTS.fetch('coverage-gaps').fetch('brief_file'))).split.join(' ')
    frontend = text.split('### Frontend contract/error-path coverage', 2).fetch(1).split('## Read-only', 2).first

    assert_includes frontend, 'Every frontend finding must include:'
    assert_includes frontend, 'A source `path:line` anchor under `frontend/src/`'
    assert_includes frontend, 'Concrete behavioral evidence: the input or failure condition, the expected contract'
    assert_includes frontend, 'behavior or error path that existing tests do not assert'
    assert_includes frontend, 'Missing tests alone are insufficient'
    assert_includes frontend, 'Relevant existing or proposed repository test paths (`frontend/src/**/*.test.{ts,tsx}`)'
    assert_includes frontend, 'identifying which test to extend or where to add an oracle'
    assert_includes frontend, 'A specific closing assertion: state exactly what the test must assert for that condition'
  end

  def test_coverage_brief_separates_frontend_evidence_from_ruby_measurements
    text = File.read(File.join(ROOT, SCOUTS.fetch('coverage-gaps').fetch('brief_file'))).split.join(' ')

    assert_includes text, 'Frontend findings are not measured by Ruby SimpleCov or Cobertura'
    assert_includes text, 'Do not infer frontend percentages or coverage gates from Ruby reports'
    assert_includes text, 'use frontend contract/test evidence instead'
    assert_includes text, 'The Ruby global 90% line/branch floors do not apply to frontend findings'
    assert_includes text, 'do not run tests or generate coverage in this read-only lane'
    assert_includes text, '`lib/**/*.rb` tracked'
    assert_includes text, '`minimum_coverage line: 90, branch: 90`'
    assert_includes text, 'Both numbers are blocking, and both are global'
    assert_includes text, '`coverage/coverage.xml`'
    assert_includes text, "Read a file's own row, never the total"
    assert_includes text, 'Nothing may be quoted from it — read the report a complete run produced'
    assert_includes text, '`bin/rake test:coverage`'
    assert_includes text, 'This lane does not run it: a coverage run flushes the test Redis DBs'
    assert_includes text, 'Read the report a run already produced'
    assert_includes text, 'A `lib/` file that no test requires'
    assert_includes text, 'High line coverage, low branch coverage on the same file'
  end

  def test_every_brief_declares_the_lane_read_only
    each_brief_text do |name, text|
      READ_ONLY_CLAUSES.each do |clause|
        assert_includes text, clause,
                        "the #{name.inspect} brief must declare the lane read-only: " \
                        "#{clause.inspect}"
      end
    end
  end

  def test_every_brief_rules_the_out_of_scope_areas_out
    each_brief_text do |name, text|
      OUT_OF_SCOPE.each do |area|
        assert_includes text, area,
                        "the #{name.inspect} brief must rule #{area.inspect} out of scope"
      end
    end
  end

  def test_every_brief_names_the_schedule_that_fires_it
    each_brief_text do |name, text|
      assert_includes text, "`schedules: #{name}`",
                      "the #{name.inspect} brief must name the schedule that fires it"
    end
  end

  def test_every_brief_dedupes_its_ask_against_the_open_issues
    each_brief_text do |name, text|
      assert_includes text, DEDUPE_CLAUSE,
                      "the #{name.inspect} brief must dedupe its ask with the paginated " \
                      'issues lookup'
    end
  end

  def test_the_committed_checkup_briefs_stay_where_their_tests_pin_them
    CHECKUP_BRIEFS.each do |name, brief_file|
      entry = schedule_for(name)

      refute_nil entry, "the policy must still carry the #{name.inspect} schedule"
      assert_equal brief_file, entry['brief_file'],
                   "the #{name.inspect} brief must stay at #{brief_file}"
      assert File.file?(File.join(ROOT, brief_file)),
             "#{brief_file} must still exist"
    end
  end

  private

  def schedule_for(name)
    @schedules.find { |entry| entry['name'] == name }
  end

  def each_brief_text
    SCOUTS.each do |name, expected|
      path = File.join(ROOT, expected['brief_file'])

      assert File.file?(path),
             "the #{name.inspect} brief must exist at #{expected['brief_file']}"

      yield(name, File.read(path))
    end
  end
end
