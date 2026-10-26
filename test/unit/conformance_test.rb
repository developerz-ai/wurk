# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/conformance'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'

class ConformanceTest < Minitest::Test
  parallelize_me!

  SOURCE = 'docs/target/sidekiq-free.md#L19'
  PROMISE = 'set of all known queue names'
  # `skipped`, not `skip`: a member named skip shadows Minitest's raising #skip.
  Result = Struct.new(:klass, :name, :assertions, :success, :skipped) do
    def passed? = success
    def skipped? = skipped
  end

  def covered(key = 'sample', refs = ['ExampleOracle#test_guard'])
    { 'id' => key, 'area' => 'redis', 'behavior' => 'Queues are a set.', 'source' => SOURCE,
      'promise' => PROMISE, 'oracles' => refs }
  end

  def pending(key = 'gap')
    covered(key).except('oracles').merge('reason' => 'No source-first oracle yet.', 'future_work' => "oracle-#{key}")
  end

  def inventory(*entries) = Conformance::Inventory.new(entries)

  def result(reference, success: true, skipped: false, assertions: 1)
    klass, name = reference.split('#')
    Result.new(klass, name, assertions, success, skipped)
  end

  def test_duplicate_ids_are_rejected
    error = assert_raises(Conformance::Invalid) { inventory(covered, covered) }
    assert_match(/duplicate id/, error.message)
  end

  def test_source_anchors_must_exist_and_identify_lines
    [nil, '', 'docs/target/sidekiq-free.md', 'docs/missing.md#L1',
     'docs/target/sidekiq-free.md#L999999', 'docs/../Rakefile.md#L1'].each do |source|
      assert_raises(Conformance::Invalid) { inventory(covered.merge('source' => source)) }
    end
  end

  def test_missing_metadata_and_malformed_entries_are_rejected
    [[], {}, [nil]].each do |entries|
      assert_raises(Conformance::Invalid) { Conformance::Inventory.new(entries) }
    end
    %w[id area behavior promise].each do |field|
      assert_raises(Conformance::Invalid) { inventory(covered.except(field)) }
    end
  end

  def test_covered_case_is_rejected_when_its_promise_is_withdrawn
    error = assert_promise_withdrawn(covered('torn'))

    assert_match(%r{torn: promise withdrawn from docs/target/sidekiq-free\.md#L19}, error.message)
  end

  def test_pending_case_is_rejected_when_its_promise_is_withdrawn
    error = assert_promise_withdrawn(pending('torn'))

    assert_match(%r{torn: promise withdrawn from docs/target/sidekiq-free\.md#L19}, error.message)
  end

  def assert_promise_withdrawn(entry)
    Dir.mktmpdir do |root|
      target = File.join(root, 'docs', 'target')
      FileUtils.mkdir_p(target)
      File.write(File.join(target, 'sidekiq-free.md'), "still here, promise withdrawn\n" * 20)
      assert_raises(Conformance::Invalid) { Conformance::Inventory.new([entry], root: root) }
    end
  end

  def test_promise_matches_with_whitespace_normalized
    promise = " | `queues` | SET |\n set of all known queue names  (without `queue:` prefix) |"

    assert inventory(covered.merge('promise' => promise))
  end

  BOUNDARY_DOC = <<~MARKDOWN
    # Queues

    Queues are the set of all known queue names.
    and more prose on a second line.

    ## Queue API

    The API keeps insertion order irrelevant.
  MARKDOWN

  def test_multiline_range_must_open_a_file_heading_or_paragraph
    rejected = {
      'docs/target/sidekiq-free.md#L4-L6' => 'mid-paragraph',
      'docs/target/sidekiq-free.md#L5-L7' => 'blank line'
    }
    accepted = {
      'docs/target/sidekiq-free.md#L1-L2' => 'Queues',
      'docs/target/sidekiq-free.md#L3-L4' => 'set of all known queue names',
      'docs/target/sidekiq-free.md#L6-L8' => 'insertion order irrelevant',
      'docs/target/sidekiq-free.md#L4' => 'more prose on a second line'
    }

    Dir.mktmpdir do |root|
      write_doc(root, 'target/sidekiq-free.md', BOUNDARY_DOC)
      rejected.each do |source, where|
        error = assert_raises(Conformance::Invalid) { inventory_with_source(root, source, PROMISE) }

        assert_match(/not at a heading or paragraph start/, error.message, "#{where}: #{source}")
      end
      accepted.each { |source, promise| assert inventory_with_source(root, source, promise), "accepted: #{source}" }
    end
  end

  LEDGER_DOC = <<~MARKDOWN
    # Divergence ledger

    ## First divergence

    First divergence body: reliable fetch moves jobs atomically.

    ## Second divergence

    Second divergence body: the deferred acknowledgement window is bounded.
  MARKDOWN

  def test_ledger_range_must_span_its_own_entry_heading
    rejected = {
      'docs/idea/parity-divergences.md#L5' => 'body only, single-line',
      'docs/idea/parity-divergences.md#L5-L9' => 'headed only by the second entry',
      'docs/idea/../idea/parity-divergences.md#L5-L9' => 'non-canonical path spelling'
    }

    Dir.mktmpdir do |root|
      write_doc(root, 'idea/parity-divergences.md', LEDGER_DOC)
      rejected.each do |source, where|
        error = assert_raises(Conformance::Invalid) do
          inventory_with_source(root, source, 'reliable fetch moves jobs atomically')
        end

        assert_equal("ledger source range omits its entry heading: #{source}", error.message, where)
      end
      assert inventory_with_source(root, 'docs/idea/parity-divergences.md#L3-L5',
                                   'reliable fetch moves jobs atomically')
      assert inventory_with_source(root, 'docs/idea/parity-divergences.md#L7-L9',
                                   'deferred acknowledgement window is bounded')
    end
  end

  def inventory_with_source(root, source, promise)
    Conformance::Inventory.new([covered.merge('source' => source, 'promise' => promise)], root: root)
  end

  def write_doc(root, relative, content)
    path = File.join(root, 'docs', relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def test_oracles_must_be_nonempty_method_references
    [nil, [], ['test_guard'], ['Example#helper'], ['Example#test_guard', 'Example#test_guard']].each do |refs|
      assert_raises(Conformance::Invalid) { inventory(covered('sample', refs)) }
    end
  end

  def test_dangling_reference_is_not_pending
    error = assert_raises(Conformance::Invalid) { inventory(covered).validate_references!([]) }
    assert_match(/missing runnable oracle ExampleOracle#test_guard/, error.message)
  end

  def test_references_are_checked_against_runnable_methods
    oracle = Class.new do
      def self.name = 'ExampleOracle'

      def test_guard; end
    end

    assert inventory(covered).validate_references!([oracle])
    oracle.class_eval { remove_method :test_guard }
    assert_raises(Conformance::Invalid) { inventory(covered).validate_references!([oracle]) }
  end

  def test_pending_requires_reason_and_unique_future_work
    %w[reason future_work].each do |field|
      [nil, '', ' '].each do |value|
        assert_raises(Conformance::Invalid) { inventory(pending.merge(field => value)) }
      end
    end
    assert_raises(Conformance::Invalid) do
      inventory(pending, pending('other').merge('future_work' => 'oracle-gap'))
    end
    assert_raises(Conformance::Invalid) { inventory(covered.merge('reason' => 'not pending')) }
  end

  def test_safe_yaml_rejects_objects_and_aliases
    require 'tempfile'
    ['--- !ruby/object:Object {}', "---\n- &case {}\n- *case\n"].each do |yaml|
      Tempfile.create(['conformance', '.yml']) do |file|
        file.write(yaml)
        file.flush
        assert_raises(Conformance::Invalid) { Conformance::Inventory.load(file.path) }
      end
    end
  end

  def test_actual_results_control_exact_totals
    entries = [covered('good'), covered('bad', ['Other#test_bad']),
               covered('skipped', ['Other#test_skip']), pending]
    output = StringIO.new
    reporter = Conformance::Reporter.new(inventory(*entries), out: output)
    reporter.record(result('ExampleOracle#test_guard'))
    reporter.record(result('Other#test_bad', success: false))
    reporter.record(result('Other#test_skip', success: false, skipped: true))
    reporter.record(result('ConformancePendingTest#test_pending_gap', success: false, skipped: true, assertions: 0))

    assert_equal({ passed: 1, pending: 1, failed: 2 }, reporter.totals)
    refute_predicate reporter, :passed?
    reporter.report

    assert_includes output.string, 'Conformance: 1 passed, 1 pending, 2 failed'
  end

  def test_all_guards_must_pass_and_missing_results_fail
    reporter = Conformance::Reporter.new(inventory(covered('both', ['One#test_a', 'Two#test_b']), pending))
    reporter.record(result('One#test_a'))

    assert_equal({ passed: 0, pending: 0, failed: 2 }, reporter.totals)
    reporter.record(result('Two#test_b', assertions: 0))

    assert_equal 0, reporter.totals[:passed]
  end

  def test_duplicate_result_does_not_erase_failure
    reporter = Conformance::Reporter.new(inventory(covered))
    reporter.record(result('ExampleOracle#test_guard', success: false))
    reporter.record(result('ExampleOracle#test_guard'))

    assert_equal({ passed: 0, pending: 0, failed: 1 }, reporter.totals)
  end

  def test_real_inventory_has_individual_unique_cases_and_existing_sources
    loaded = Conformance::Inventory.load(File.expand_path('../conformance/cases.yml', __dir__))

    assert_operator loaded.covered.size, :>, 40
    assert_operator loaded.pending.size, :>, 0
    assert_includes loaded.covered.flat_map { |entry| entry['oracles'] },
                    'ClientPushParityTest#test_args_round_trip_through_json'
    assert_includes loaded.covered.flat_map { |entry| entry['oracles'] },
                    'ClientPushParityTest#test_immediate_push_touches_only_queues_set_and_queue_list'
  end

  def test_real_inventory_references_all_error_expiry_metrics_and_sorted_entry_oracles
    loaded = Conformance::Inventory.load(File.expand_path('../conformance/cases.yml', __dir__))
    references = loaded.covered.flat_map { |entry| entry.fetch('oracles') }

    assert_equal 27, required_inventory_references.uniq.size
    required_inventory_references.each { |reference| assert_includes references, reference }
  end

  def test_in_flight_expiration_remains_pending
    loaded = Conformance::Inventory.load(File.expand_path('../conformance/cases.yml', __dir__))
    entry = loaded.pending.find { |candidate| candidate.fetch('id') == 'expiry.non-preemption' }

    refute_nil entry
    assert_equal 'oracle-expiry-in-flight-non-preemption', entry.fetch('future_work')
    refute_empty entry.fetch('reason')
    refute_includes entry, 'oracles'
  end

  def test_real_inventory_accounts_for_successful_and_pending_results_exactly
    loaded = Conformance::Inventory.load(File.expand_path('../conformance/cases.yml', __dir__))
    references = loaded.covered.flat_map { |entry| entry.fetch('oracles') }.uniq
    reporter = Conformance::Reporter.new(loaded, out: StringIO.new)

    assert_equal({ passed: 0, pending: 0, failed: loaded.cases.size }, reporter.totals)
    references.each { |reference| reporter.record(result(reference)) }

    assert_equal({ passed: loaded.covered.size, pending: 0, failed: loaded.pending.size }, reporter.totals)

    record_inventory_pending_skips(reporter, loaded)
    expected = { passed: loaded.covered.size, pending: loaded.pending.size, failed: 0 }

    assert_equal expected, reporter.totals
    assert_predicate reporter, :passed?
  end

  def test_real_inventory_rejects_missing_failed_skipped_and_assertionless_results
    loaded = Conformance::Inventory.load(File.expand_path('../conformance/cases.yml', __dir__))
    references = loaded.covered.flat_map { |entry| entry.fetch('oracles') }.uniq
    outcomes = [nil, { success: false }, { skipped: true }, { assertions: 0 }]

    required_inventory_references.product(outcomes).each do |unsuccessful, outcome|
      assert_inventory_rejects_unsuccessful_result(loaded, references, unsuccessful, outcome)
    end
  end

  def assert_inventory_rejects_unsuccessful_result(loaded, references, unsuccessful, outcome)
    failed_reporter = Conformance::Reporter.new(loaded, out: StringIO.new)
    (references - [unsuccessful]).each { |reference| failed_reporter.record(result(reference)) }
    failed_reporter.record(result(unsuccessful, **outcome)) if outcome
    record_inventory_pending_skips(failed_reporter, loaded)
    affected = loaded.covered.count { |entry| entry.fetch('oracles').include?(unsuccessful) }

    expected = { passed: loaded.covered.size - affected, pending: loaded.pending.size, failed: affected }

    assert_operator affected, :>, 0, unsuccessful
    assert_equal expected, failed_reporter.totals, "#{unsuccessful}: #{outcome.inspect}"
    refute_predicate failed_reporter, :passed?
  end

  def record_inventory_pending_skips(reporter, loaded)
    loaded.pending.each do |entry|
      reference = "ConformancePendingTest#test_pending_#{entry.fetch('id').tr('.-', '__')}"
      reporter.record(result(reference, success: false, skipped: true, assertions: 0))
    end
  end

  def required_inventory_references
    %w[
      ErrorHandlersParityTest#test_a_failing_job_calls_each_handler_once
      ErrorHandlersParityTest#test_the_handler_receives_the_jobs_own_exception
      ErrorHandlersParityTest#test_the_context_names_the_job_failure_and_carries_the_job
      ErrorHandlersParityTest#test_the_handler_receives_the_configuration
      ErrorHandlersParityTest#test_a_job_without_retries_is_reported_once
      ErrorHandlersParityTest#test_an_exhausted_job_is_reported_once
      ErrorHandlersParityTest#test_a_successful_job_reports_nothing
      ErrorHandlersParityTest#test_a_skip_reports_nothing
      ErrorHandlersParityTest#test_a_raising_handler_does_not_stop_the_next
      ExpiringParityTest#test_worker_option_stores_expiry_as_created_at_plus_duration
      ExpiringParityTest#test_set_override_replaces_the_worker_duration
      ExpiringParityTest#test_set_override_on_a_worker_without_the_option
      ExpiringParityTest#test_no_expiry_without_the_option
      ExpiringParityTest#test_scheduled_job_expires_duration_after_it_is_due
      ExpiringParityTest#test_job_in_time_runs
      ExpiringParityTest#test_expired_job_is_skipped_and_not_retried
      ExpiringParityTest#test_expired_job_counts_as_success_in_a_batch
      MetricsQueryParityTest#test_minutely_buckets_feed_top_jobs_totals
      MetricsQueryParityTest#test_averages_divide_by_completed_executions
      MetricsQueryParityTest#test_hourly_reads_ten_minute_buckets
      MetricsQueryParityTest#test_for_job_reads_one_class
      MetricsQueryParityTest#test_window_caps
      MetricsQueryParityTest#test_marks_come_from_the_day_marks_hash
      MetricsQueryParityTest#test_executed_jobs_land_in_the_spec_minute_key
      SortedEntryApiParityTest#test_retry_pushed_payload_matches_sidekiq
      SortedEntryApiParityTest#test_add_to_queue_pushed_payload_matches_sidekiq
      SortedEntryApiParityTest#test_kill_fires_death_handlers_with_api_exception
    ]
  end

  def test_parity_discovery_retains_every_oracle_and_adds_conformance
    script = <<~RUBY
      require 'rake'
      load 'Rakefile'
      task = Rake.application.tasks.find { |candidate| candidate.name == 'test:parity' }
      abort 'missing parity task' unless task
      Rake::FileUtilsExt.verbose(false) do
        module Rake::FileUtilsExt
          def ruby(*arguments, **)
            puts arguments.join(' ')
          end
        end
        task.invoke
      end
    RUBY
    output, status = Open3.capture2e({ 'COVERAGE' => nil, 'TEST' => nil }, RbConfig.ruby, '-e', script,
                                     chdir: Conformance::ROOT)

    assert_predicate status, :success?, output
    Dir['test/parity/**/*_test.rb'].each { |path| assert_includes output, path }
    assert_includes output, 'test/conformance/conformance_test.rb'
  end

  def test_forked_results_are_aggregated_and_failures_exit_nonzero
    [false, true].each { |fail_guard| assert_forked_conformance_totals(fail_guard) }
  end

  def assert_forked_conformance_totals(fail_guard)
    entries = [covered('first', ['FirstOracle#test_first']),
               covered('second', ['SecondOracle#test_second']), pending].inspect
    script = <<~RUBY
      require 'minitest/autorun'
      require 'minitest/parallel_fork'
      require_relative 'test/support/conformance'
      class FirstOracle < Minitest::Test
        parallelize_me!
        def test_first
          assert true
        end
      end
      class SecondOracle < Minitest::Test
        parallelize_me!
        def test_second
          assert #{!fail_guard}
        end
      end
      entries = #{entries}
      Conformance.install(Conformance::Inventory.new(entries))
    RUBY
    output, status = Open3.capture2e({ 'COVERAGE' => nil, 'NCPU' => '2' }, RbConfig.ruby, '-e', script,
                                     chdir: Conformance::ROOT)
    expected = if fail_guard
                 'Conformance: 1 passed, 1 pending, 1 failed'
               else
                 'Conformance: 2 passed, 1 pending, 0 failed'
               end

    assert_includes output, expected
    assert_equal !fail_guard, status.success?, output
  end
end
