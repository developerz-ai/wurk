# frozen_string_literal: true

module Wurk
  module Test
    # Answers one question about a finished COVERAGE run: did every forked
    # parallel worker's resultset reach the merge? SimpleCov merges whatever
    # entries it finds and gates on the total, so a run that lost a worker's
    # entry reports ~85% and fails as if the code were under-tested — a verdict
    # on data nobody collected (#566 failed that way on a fully green suite).
    # test_helper asks this before SimpleCov reports and fails the run by name
    # instead. Pure functions over the parsed coverage/.resultset.json, so the
    # rule is testable without a coverage run.
    module CoverageMerge
      module_function

      # The key a worker stores under: SimpleCov's default at_fork proc builds
      # it from the parent's command name and the label test_helper passes.
      def worker_command_name(base, worker)
        "#{base} (subprocess: worker-#{worker})"
      end

      # Worker indices whose entry the merge will not contain. An entry counts
      # only if THIS run stored it (`since`: a coverage/ left by an earlier run
      # can hold a same-named entry) and SimpleCov will still merge it (it
      # silently drops entries older than merge_timeout).
      def missing_workers(resultset, base:, workers:, since:, now:, merge_timeout:)
        (0...workers).reject do |worker|
          stored_at = resultset.dig(worker_command_name(base, worker), 'timestamp')
          stored_at && stored_at >= since && now - stored_at < merge_timeout
        end
      end

      def failure_message(missing)
        "coverage merge incomplete: missing #{missing.map { |worker| "worker-#{worker}" }.join(', ')} — " \
          'no line/branch percentage is reported, because it would describe only part of the suite. ' \
          'Each named worker has no resultset entry from this run in coverage/.resultset.json ' \
          '(never stored, deleted mid-run, or older than SimpleCov.merge_timeout).'
      end
    end
  end
end
