# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# bench.yml's `commands per job` job runs bench/command_count.rb, which fails
# above its BUDGET and below its BASELINE. Those two defaults are the recorded
# number; docs/benchmarks.md publishes it. Equal budget and baseline make any
# added per-job command red, and the docs must quote the number the gate holds.
class CommandCountBaselineTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  SCRIPT = File.join(ROOT, 'bench', 'command_count.rb')
  DOC = File.join(ROOT, 'docs', 'benchmarks.md')
  BENCH_YML = File.join(ROOT, '.github', 'workflows', 'bench.yml')

  def recorded(name)
    match = File.read(SCRIPT).match(/^#{name} = Float\(ENV\.fetch\('WURK_BENCH_CMD_#{name}', '([\d.]+)'\)\)$/)

    refute_nil match, "bench/command_count.rb no longer defines #{name} with an env-overridable default"
    Float(match[1])
  end

  def test_the_budget_allows_no_increase_over_the_baseline
    assert_equal recorded('BASELINE'), recorded('BUDGET'),
                 'a budget above the baseline lets a new per-job command through CI'
  end

  def test_docs_publish_the_recorded_baseline
    total = File.read(DOC)[/^\s+\d+\s+(\d+\.\d+)\s+total$/, 1]

    refute_nil total, 'docs/benchmarks.md lost the command_count table'
    assert_in_delta recorded('BASELINE'), Float(total), 0.005,
                    're-baseline bench/command_count.rb and docs/benchmarks.md together'
  end

  def test_ci_runs_the_gate_on_bench_inputs
    job = YAML.load_file(BENCH_YML).dig('jobs', 'command-count')

    refute_nil job, 'bench.yml lost the commands-per-job job'
    assert_includes job['steps'].map { |step| step['run'] }, 'bundle exec rake bench:command_count'
  end
end
