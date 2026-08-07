# frozen_string_literal: true

require_relative '../test_helper'
require 'English'

# `rake bench` pipes every GATE_SCRIPT's stdout into bin/bench-compare, which
# reads benchmark/ips report lines and nothing else — and BENCH_SCRIPTS is a
# glob, so a new bench/*.rb joins the gate the moment it lands. A script that
# reports in any other shape (a Markdown table, a command tally) contributes no
# parseable label, which bench-compare then reads as a benchmark that vanished
# on head and fails the gate on every PR. The Rakefile's opt-out list is the
# only thing preventing that, so it is pinned here.
class BenchGateScriptsTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)

  # Not ips reports: vs_sidekiq.rb prints a Markdown comparison table,
  # command_count.rb an INFO commandstats tally plus a per-job budget assertion.
  UNGATED = %w[vs_sidekiq.rb command_count.rb].freeze

  def test_scripts_that_are_not_ips_reports_stay_out_of_the_gate
    UNGATED.each do |script|
      assert_includes bench_scripts, script, "bench/#{script} must still be runnable as `rake bench:#{script[..-4]}`"
      refute_includes gate_scripts, script, "bench/#{script} is not an ips report — bin/bench-compare can't read it"
    end
  end

  def test_every_other_bench_script_is_gated
    assert_equal (bench_scripts - UNGATED).sort, gate_scripts.sort,
                 'a new bench/*.rb is gated by default; opt it out in the Rakefile only if it is not an ips report'
    refute_includes bench_scripts, 'support.rb', 'the shared helper is not a benchmark'
  end

  private

  def bench_scripts
    @bench_scripts ||= rakefile_constant('BENCH_SCRIPTS')
  end

  def gate_scripts
    @gate_scripts ||= rakefile_constant('GATE_SCRIPTS')
  end

  # Loading the Rakefile defines its tasks, so it happens in a subprocess rather
  # than inside a test worker. One spawn answers for both constants.
  def rakefile_constant(name)
    @rakefile_constants ||= begin
      script = 'extend Rake::DSL; load "Rakefile"; ' \
               'puts [BENCH_SCRIPTS, GATE_SCRIPTS].map { |s| s.map { |p| File.basename(p) }.join(",") }'
      out = IO.popen({}, [RbConfig.ruby, '-r', 'rake', '-e', script], chdir: ROOT, err: %i[child out], &:read)

      assert_equal 0, $CHILD_STATUS.exitstatus, "loading the Rakefile failed:\n#{out}"
      names = out.lines.last(2).map { |line| line.strip.split(',') }
      { 'BENCH_SCRIPTS' => names.first, 'GATE_SCRIPTS' => names.last }
    end
    @rakefile_constants.fetch(name)
  end
end
