# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../support/conformance'
require 'open3'
require 'rbconfig'
require 'stringio'

class ConformanceTest < Minitest::Test
  parallelize_me!

  SOURCE = 'docs/target/sidekiq-free.md#L19'
  Result = Struct.new(:klass, :name, :assertions, :success, :skip) do
    def passed? = success
    def skipped? = skip
  end

  def covered(id = 'sample', refs = ['ExampleOracle#test_guard'])
    { 'id' => id, 'area' => 'redis', 'behavior' => 'Queues are a set.', 'source' => SOURCE, 'oracles' => refs }
  end

  def pending(id = 'gap')
    covered(id).except('oracles').merge('reason' => 'No source-first oracle yet.', 'future_work' => "oracle-#{id}")
  end

  def inventory(*entries) = Conformance::Inventory.new(entries)

  def result(reference, success: true, skip: false, assertions: 1)
    klass, name = reference.split('#')
    Result.new(klass, name, assertions, success, skip)
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
    %w[id area behavior].each do |field|
      assert_raises(Conformance::Invalid) { inventory(covered.except(field)) }
    end
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
    runnable = Struct.new(:name, :runnable_methods).new('ExampleOracle', ['test_guard'])
    assert inventory(covered).validate_references!([runnable])
    runnable.runnable_methods.clear
    assert_raises(Conformance::Invalid) { inventory(covered).validate_references!([runnable]) }
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
    reporter = Conformance::Reporter.new(inventory(*entries), io: output)
    reporter.record(result('ExampleOracle#test_guard'))
    reporter.record(result('Other#test_bad', success: false))
    reporter.record(result('Other#test_skip', success: false, skip: true))
    reporter.record(result('ConformancePendingTest#test_pending_gap', success: false, skip: true, assertions: 0))
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

  def test_parity_discovery_retains_every_oracle_and_adds_conformance
    script = <<~'RUBY'
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
    output, status = Open3.capture2e({ 'COVERAGE' => nil }, RbConfig.ruby, '-e', script,
                                    chdir: Conformance::ROOT)
    assert_predicate status, :success?, output
    Dir['test/parity/**/*_test.rb'].each { |path| assert_includes output, path }
    assert_includes output, 'test/conformance/conformance_test.rb'
  end

  def test_forked_results_are_aggregated_and_failures_exit_nonzero
    [false, true].each do |fail_guard|
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
        entries = #{[covered('first', ['FirstOracle#test_first']), covered('second', ['SecondOracle#test_second']), pending].inspect}
        Conformance.install(Conformance::Inventory.new(entries))
      RUBY
      output, status = Open3.capture2e({ 'COVERAGE' => nil, 'NCPU' => '2' }, RbConfig.ruby, '-e', script,
                                      chdir: Conformance::ROOT)
      expected = fail_guard ? 'Conformance: 1 passed, 1 pending, 1 failed' :
                              'Conformance: 2 passed, 1 pending, 0 failed'
      assert_includes output, expected
      assert_equal !fail_guard, status.success?, output
    end
  end
end
