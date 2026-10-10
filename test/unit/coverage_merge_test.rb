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
end
