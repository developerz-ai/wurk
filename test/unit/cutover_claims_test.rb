# frozen_string_literal: true

require 'minitest/autorun'

# Running Sidekiq and Wurk workers against one Redis at the same time is not
# tested (audit R4: Wurk's five-segment private lists are never reclaimed by
# stock Sidekiq; Enterprise leader election and unique locks are unexercised
# across the two). The supported production path is the drain cutover in
# docs/migrate-from-sidekiq.md §9. Until an integration test proves a mixed
# fleet, no public doc may promise one, nor a rollback that skips the drain.
# Reads files and touches no Redis or shared state.
class CutoverClaimsTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)

  MIXED_FLEET_CLAIMS = [
    /rolling deploy (?:is safe|can run Sidekiq and Wurk)/i,
    /mixed fleet[^.]*\bis safe/i,
    /\broll back any ?time\b/i,
    /(?:Sidekiq and Wurk|both) (?:processes )?can run against the same Redis/i
  ].freeze

  # §4's key-layout row for the batch keys used to read "✅ Pro batch schema",
  # which contradicted the guide's own §9 cutover warning: Wurk's
  # `b-<bid>-success` / `b-<bid>-complete` markers mean "already fired"
  # (callbacks enqueued, not necessarily executed), while Pro §2.8 describes the
  # same keys as "callbacks pending" — so a Pro batch in flight at the swap may
  # miss its callbacks. Nothing in the suite pinned the qualified row (the
  # anchor test only resolves links, the claim tests only forbid mixed fleets
  # and speed/scale/progress claims), so a copy edit could restore the
  # contradiction silently.
  BATCH_ROW_PREFIX = '| `b-<bid>*`, `batches` |'
  UNQUALIFIED_BATCH_CLAIM = /✅\s*Pro batch schema/
  CUTOVER_WARNING_ANCHOR = '#behaviour-differences-to-know-before-cutover'
  CUTOVER_WARNING_HEADING = '### Behaviour differences to know before cutover'

  def surfaces
    docs = Dir[File.join(ROOT, 'docs', '*.md')] + Dir[File.join(ROOT, 'docs', 'wiki', '*.md')]
    (docs + %w[README.md docs/site/llms.txt docs/site/index.html].map { |rel| File.join(ROOT, rel) }).sort
  end

  def guide_lines
    @guide_lines ||= File.readlines(File.join(ROOT, 'docs/migrate-from-sidekiq.md'))
  end

  def guide_text
    @guide_text ||= guide_lines.join
  end

  # One "## N. …" section, whitespace-normalised so a re-wrapped paragraph
  # still matches the phrase a test pins.
  def section(number)
    lines = guide_lines
    from = lines.index { |line| line.start_with?("## #{number}. ") }
    return '' if from.nil?

    (lines[(from + 1)..] || []).take_while { |line| !line.start_with?('## ') }.join.gsub(/\s+/, ' ')
  end

  def test_no_doc_promises_a_mixed_fleet_or_an_undrained_rollback
    offenders = surfaces.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        next unless MIXED_FLEET_CLAIMS.any? { |re| line.match?(re) }

        "#{path.delete_prefix("#{ROOT}/")}:#{i + 1}: #{line.strip[0, 140]}"
      end
    end

    assert_empty offenders,
                 'a mixed Sidekiq + Wurk fleet is untested; document the drain cutover ' \
                 "(docs/migrate-from-sidekiq.md §9) instead:\n#{offenders.join("\n")}"
  end

  def test_the_migration_guide_keeps_its_cutover_and_rollback_procedure
    guide = File.read(File.join(ROOT, 'docs/migrate-from-sidekiq.md'))

    ['## 9. Production cutover', '### 9.1 Pre-flight checklist', '### 9.2 Drain Sidekiq',
     '### 9.4 Verify', '### 9.5 Rollback'].each do |heading|
      assert_includes guide, heading
    end
    assert_includes guide, "--pattern 'queue:*|*'", 'the private-list check is the step rollback depends on'
  end

  def test_the_guard_catches_the_claims_it_replaced
    [
      'so a rolling deploy can run Sidekiq and Wurk against the same Redis during the cutover.',
      '**Because the Redis schema is identical, a rolling deploy is safe**',
      'a mixed fleet (some Sidekiq, some Wurk) on one Redis is safe, and',
      '8. **Roll back anytime** — revert the `Gemfile` line.'
    ].each { |claim| assert_match Regexp.union(MIXED_FLEET_CLAIMS), claim }
  end

  def test_the_batch_schema_row_is_qualified_by_the_marker_semantics
    row = guide_lines.find { |line| line.start_with?(BATCH_ROW_PREFIX) }

    refute_nil row, "the §4 key-layout row #{BATCH_ROW_PREFIX.inspect} is gone from the migration guide"
    refute_match UNQUALIFIED_BATCH_CLAIM, row,
                 '§4 promised unqualified Pro batch-schema compatibility; §9 says a Pro batch in ' \
                 'flight at the swap may miss its callbacks'
    assert_includes row, '"already fired"'
    assert_includes row, '"callbacks pending"'
    assert_includes row, 'may miss callbacks'
    assert_includes row, CUTOVER_WARNING_ANCHOR
    assert_includes guide_text, CUTOVER_WARNING_HEADING
  end

  def test_section_four_warns_in_its_own_words_that_a_batch_in_flight_is_not_covered
    prose = section(4)

    assert_includes prose, 'A batch in flight at the swap is not covered by the batch-schema claim'
    assert_includes prose, 'callbacks may not fire'
    assert_includes prose, 'let critical batches finish before the cutover'
    assert_includes prose, CUTOVER_WARNING_ANCHOR
  end

  def test_the_section_nine_warning_row_still_says_what_section_four_qualifies
    row = guide_lines.find { |line| line.start_with?('| Wurk uses `b-<bid>-success`') }

    refute_nil row, 'the §9 cutover warning lost its batch-marker row'
    assert_includes row, '"already fired"'
    assert_includes row, '"callbacks pending"'
    assert_includes row, 'A Pro batch in flight at the swap may miss callbacks'
    assert_includes row, 'Let critical batches finish before the cutover'
  end

  def test_the_guard_catches_the_unqualified_batch_claim
    assert_match UNQUALIFIED_BATCH_CLAIM,
                 '| `b-<bid>*`, `batches` | HASH/SET/ZSET | ✅ Pro batch schema |'
  end
end
