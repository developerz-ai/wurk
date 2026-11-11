# frozen_string_literal: true

require 'minitest/autorun'

# Claims the migration guide once made and that a live cutover would have paid for.
# Reads files only.
class MigrationGuideClaimsTest < Minitest::Test
  parallelize_me!

  GUIDE = File.read(File.expand_path('../../docs/migrate-from-sidekiq.md', __dir__))

  def row_for(option) = GUIDE.lines.find { |line| line.start_with?("| `lock: :#{option}`") }

  def test_while_executing_is_not_mapped_to_a_start_lock
    assert_includes row_for('while_executing'), 'No equivalent'
    refute_includes GUIDE, '| `lock: :until_executing` / `:while_executing`'
  end

  def test_on_conflict_reschedule_says_it_has_no_native_equivalent
    assert_match(/`on_conflict: :reschedule`.*No equivalent/, GUIDE)
  end

  def test_the_default_scheduler_is_not_called_lossy
    refute_match(/job-loss window/, GUIDE)
    refute_match(/`config\.reliable_scheduler!` is \*\*on\*\*/, GUIDE)
    assert_match(/reliable_scheduler!.*optional/m, GUIDE)
  end

  def test_leftover_gem_locks_are_unlinked_on_rollback
    rollback = GUIDE[/^### 9\.5 Rollback.*?^### /m]

    assert_match(/UNLINK/, rollback)
    assert_match(/uniquejobs/, rollback)
    refute_match(/Leftover gem locks do nothing/, GUIDE)
  end

  def test_encrypted_jobs_are_not_said_to_carry_over_on_the_same_keys
    refute_match(/\*\*same\*\* encryption keys/, GUIDE)
    assert_match(/Encrypted jobs drained before the cutover/, GUIDE)
  end

  def test_a_7x_rollback_warns_about_milliseconds
    section = GUIDE[/^### Millisecond timestamps.*?^### /m]

    assert_match(/retry_for/, section)
    assert_match(/latency/, section)
    assert_match(/58807/, section)
  end

  # The wiki and docs/sentry.md repeat the guide's gotchas and drifted from it:
  # clustered Puma refuses to fork (Wurk::RailsBoot#refuse_preforking_boot),
  # sentry-sidekiq installs through the shim and its suite runs in CI, and the
  # reliable scheduler is optional. A poison kill fires death handlers, and
  # PoisonPill.track! was replaced by recovered! (Fetcher::OrphanReclaim).
  RETIRED_CLAIMS = {
    'clustered Puma forking a duplicate swarm' => /fork(?:s|ing)? (?:a )?duplicate swarms?/i,
    'sentry-sidekiq being uninstallable' => /cannot be installed/i,
    'reliable_scheduler! as a must-keep' => /reliable_scheduler!.{0,60}keep it/i,
    'the dashboard not rendering ERB extensions' => /does not render ERB extensions/i,
    'sidekiq-cron as the only gem with its suite in CI' => /only \W*sidekiq-cron\W* (?:is|has)/i,
    'poison kills skipping death handlers' => /death_handlers`?\*{0,2} do\s+(?:\*\*)?not fire/i,
    'the removed PoisonPill.track!' => /PoisonPill\.track!|`track!`/
  }.freeze

  def test_retired_claims_stay_out_of_the_guides_and_wiki
    root = File.expand_path('../..', __dir__)
    files = %w[docs/migrate-from-sidekiq.md docs/sentry.md docs/retries.md docs/middleware.md docs/reliability.md] +
            Dir[File.join(root, 'docs/wiki/*.md')].map { |f| f.delete_prefix("#{root}/") }
    offenders = files.product(RETIRED_CLAIMS.to_a).filter_map do |file, (claim, pattern)|
      "#{file}: #{claim}" if File.read(File.join(root, file)).match?(pattern)
    end

    assert_empty offenders, "retired claims are back:\n#{offenders.join("\n")}"
  end

  def test_each_kept_gem_is_marked_with_what_was_verified
    section = GUIDE[/^### What was verified.*?^### /m]

    %w[sidekiq-cron sidekiq-unique-jobs sidekiq-failures sentry-sidekiq opentelemetry-instrumentation-sidekiq
       rspec-sidekiq].each { |gem| assert_match(/^\| `#{gem}` /, section, gem) }
  end
end
