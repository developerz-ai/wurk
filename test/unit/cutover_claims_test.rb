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

  def surfaces
    docs = Dir[File.join(ROOT, 'docs', '*.md')] + Dir[File.join(ROOT, 'docs', 'wiki', '*.md')]
    (docs + %w[README.md docs/site/llms.txt docs/site/index.html].map { |rel| File.join(ROOT, rel) }).sort
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
end
