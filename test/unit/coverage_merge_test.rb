# frozen_string_literal: true

require_relative '../test_helper'

# The rule test_helper applies before SimpleCov reports under COVERAGE=1: a
# merge that lacks any forked worker's resultset is a failed run named as such,
# never a percentage. Fed the shapes coverage/.resultset.json really took in CI.
class CoverageMergeTest < Minitest::Test
  parallelize_me!

  Merge = Wurk::Test::CoverageMerge

  BASE = 'Integration Tests'
  STARTED = 1_000_000
  NOW = STARTED + 300

  def entry(stored_at)
    { 'coverage' => {}, 'timestamp' => stored_at }
  end

  def missing(resultset, workers: 2, merge_timeout: 600)
    Merge.missing_workers(resultset, base: BASE, workers: workers, since: STARTED, now: NOW,
                                     merge_timeout: merge_timeout)
  end

  def test_worker_key_is_the_one_simplecovs_at_fork_proc_stores_under
    assert_equal 'Integration Tests (subprocess: worker-1)', Merge.worker_command_name(BASE, 1)
  end

  def test_nothing_is_missing_when_every_worker_stored_during_this_run
    resultset = {
      BASE => entry(NOW),
      Merge.worker_command_name(BASE, 0) => entry(STARTED),
      Merge.worker_command_name(BASE, 1) => entry(NOW - 1)
    }

    assert_empty missing(resultset)
  end

  # Run 37283426244: 4834 runs, 0 failures, and only worker-1 in the merge.
  def test_an_absent_worker_entry_is_missing
    resultset = { BASE => entry(NOW), Merge.worker_command_name(BASE, 1) => entry(NOW) }

    assert_equal [0], missing(resultset)
  end

  def test_an_empty_resultset_is_missing_every_worker
    assert_equal [0, 1, 2], missing({}, workers: 3)
  end

  # The second worker to finish also stores the merged result under the joined
  # name; that key holding "worker-0" in its text is not worker-0's entry.
  def test_a_joined_merge_key_does_not_stand_in_for_a_worker
    joined = "#{Merge.worker_command_name(BASE, 0)}, #{Merge.worker_command_name(BASE, 1)}"
    resultset = { joined => entry(NOW), Merge.worker_command_name(BASE, 1) => entry(NOW) }

    assert_equal [0], missing(resultset)
  end

  def test_an_entry_left_by_an_earlier_run_is_missing
    resultset = {
      Merge.worker_command_name(BASE, 0) => entry(STARTED - 1),
      Merge.worker_command_name(BASE, 1) => entry(NOW)
    }

    assert_equal [0], missing(resultset)
  end

  # SimpleCov drops an entry once it is merge_timeout old, so a worker that
  # finished that long before the merge contributes nothing however intact
  # its entry is.
  def test_an_entry_simplecov_will_no_longer_merge_is_missing
    resultset = {
      Merge.worker_command_name(BASE, 0) => entry(NOW - 100),
      Merge.worker_command_name(BASE, 1) => entry(NOW - 99)
    }

    assert_equal [0], missing(resultset, merge_timeout: 100)
  end

  def test_another_command_names_workers_do_not_count
    resultset = {
      Merge.worker_command_name('Unit Tests', 0) => entry(NOW),
      Merge.worker_command_name('Unit Tests', 1) => entry(NOW)
    }

    assert_equal [0, 1], missing(resultset)
  end

  def test_failure_message_names_each_missing_worker
    message = Merge.failure_message([0, 3])

    assert_match(/\Acoverage merge incomplete: missing worker-0, worker-3\b/, message)
  end

  # The wiring test_helper's after_run hook calls. Needs a real coverage run to
  # have SimpleCov and the fork count; CI's one suite run is COVERAGE=1.
  def verify_against(resultset)
    skip 'needs SimpleCov and minitest-parallel_fork (COVERAGE=1)' unless verifiable?

    stopped = []
    status = nil
    read = resultset.call
    _, err = capture_io do
      swap(SimpleCov::ResultMerger, :read_resultset, -> { read }) do
        swap(SimpleCov, :running=, ->(value) { stopped << value }) do
          Merge.verify!(since: Time.now.to_i - 1)
        rescue SystemExit => e
          status = e
        end
      end
    end
    [status, stopped, err]
  end

  # Minitest 6 dropped minitest/mock; swap one singleton method and restore it.
  def swap(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name, &replacement)
    yield
  ensure
    target.define_singleton_method(name, original)
  end

  def complete_resultset
    Array.new(Minitest.parallel_fork_number) do |worker|
      [Merge.worker_command_name(SimpleCov.command_name, worker), entry(Time.now.to_i)]
    end.to_h
  end

  def verifiable?
    defined?(SimpleCov) && Minitest.respond_to?(:parallel_fork_number)
  end

  def test_verify_fails_the_run_by_name_and_stops_simplecov_reporting
    status, stopped, err = verify_against(-> { {} })

    refute_nil status, 'an incomplete merge must abort the run'
    refute_predicate status, :success?
    assert_equal [false], stopped
    assert_match(/\Acoverage merge incomplete: missing worker-0\b/, err)
  end

  def test_verify_leaves_a_complete_merge_to_simplecov
    status, stopped, err = verify_against(-> { complete_resultset })

    assert_nil status
    assert_empty stopped
    assert_empty err
  end
end
