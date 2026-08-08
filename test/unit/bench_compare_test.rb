# frozen_string_literal: true

require_relative '../test_helper'
require 'English'
require 'tmpdir'

# Drives bin/bench-compare against synthetic `rake bench` output so the bench
# gate's noise handling — and the best-of-N de-noising added for #250 — is
# covered without running the (slow, noisy) real benchmarks.
class BenchCompareTest < Wurk::Test::UnitCase
  parallelize_me!

  SCRIPT = File.expand_path('../../bin/bench-compare', __dir__)

  # bench/memory.rb's two series, verbatim. Both carry a parenthesized group and
  # a `1k`/`/1k` fragment — the exact shape that could make IPS_LINE's non-greedy
  # label capture swallow part of the value — so pin the real strings, not
  # stand-ins.
  ALLOC_LABEL     = 'wurk hot-path (jobs/1k-alloc)'
  RETENTION_LABEL = 'wurk hot-path (retention-free/1k)'

  # benchmark/ips report line, as bin/bench-compare parses it.
  def ips_line(label, ips, err)
    format('%s   %.1f (± %.1f%%) i/s -    1.00k in   5.000s', label, ips, err)
  end

  # rows: [label, ips, err] triples, one report line each.
  def write_report(tag, rows)
    path = File.join(@dir, "#{tag.gsub(/\W+/, '_')}_#{object_id}_#{rows.hash.abs}.txt")
    File.write(path, rows.map { |label, ips, err| ips_line(label, ips, err) }.join("\n") << "\n")
    path
  end

  def write_runs(label, *runs)
    write_report(label, runs.map { |ips, err| [label, ips, err] })
  end

  # Pin BENCH_REGRESSION_PCT to the script's documented default so the gate's
  # threshold is decoupled from whatever the parent test process (or CI) has
  # in its environment — otherwise these assertions drift on env coupling.
  def compare(base, head)
    out = IO.popen({ 'BENCH_REGRESSION_PCT' => '5' }, [SCRIPT, base, head], err: %i[child out], &:read)
    [out, $CHILD_STATUS.exitstatus]
  end

  def setup
    super
    @dir = Dir.mktmpdir('bench-compare')
    @label = 'wurk push_bulk(1000)'
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  ensure
    super
  end

  # The #250 false-positive: a single noisy head sample clears the noise band.
  def test_single_noisy_sample_trips_the_gate
    base = write_runs(@label, [251.0, 4.15])
    head = write_runs(@label, [206.0, 4.15])

    out, code = compare(base, head)

    assert_equal 1, code, 'a -18% drop over a ±13.3% band must flag'
    assert_includes out, '🔴 regressed'
  end

  # Best-of-N rescue: same noisy run plus two clean runs => fastest wins, passes.
  def test_best_of_n_keeps_the_fastest_run_and_clears_noise
    base = write_runs(@label, [251.0, 4.15], [254.0, 4.15], [249.0, 4.15])
    head = write_runs(@label, [206.0, 4.15], [250.0, 4.15], [248.0, 4.15])

    out, code = compare(base, head)

    assert_equal 0, code, 'fastest head run (250) vs fastest base (254) is within noise'
    assert_includes out, '| 254 | 250 |', 'table must report the best-of-N ips, not the noisy sample'
    refute_includes out, '🔴 regressed'
  end

  # Best-of-N must not mask a real regression present across every run.
  def test_real_regression_survives_best_of_n
    base = write_runs(@label, [251.0, 4.15], [254.0, 4.15])
    head = write_runs(@label, [176.0, 4.15], [178.0, 4.15])

    out, code = compare(base, head)

    assert_equal 1, code, 'a ~30% drop on every run must still flag'
    assert_includes out, '🔴 regressed'
  end

  # A baseline benchmark missing on head still fails the gate (anti-hiding).
  def test_missing_benchmark_on_head_fails
    base = write_runs(@label, [251.0, 4.15])
    head = write_runs('wurk enqueue', [5700.0, 6.9])

    out, code = compare(base, head)

    assert_equal 1, code
    assert_includes out, 'Missing on head'
  end

  # bench/memory.rb emits both series as benchmark/ips lines purely so this
  # script can gate them. If IPS_LINE ever stops matching those labels the memory
  # bench silently drops out of the comparison and reports nothing — so assert on
  # the parsed rows, not just an exit code.
  def test_memory_bench_series_parse_and_compare
    rows = ->(alloc, retention) { [[ALLOC_LABEL, alloc, 0.2], [RETENTION_LABEL, retention, 0.0]] }
    base = write_report('memory-base', rows.call(4210.0, 1000.0))
    head = write_report('memory-head', rows.call(4208.0, 1000.0))

    out, code = compare(base, head)

    assert_equal 0, code
    assert_includes out, "| `#{ALLOC_LABEL}` | 4.21k | 4.21k |"
    assert_includes out, "| `#{RETENTION_LABEL}` | 1.00k | 1.00k | +0.0% | 🟢 |"
  end

  # The point of the retention series: a hot path that retains one slot per job
  # halves the score, and the gate treats that exactly like an i/s regression.
  # Allocation rate alone cannot see this — it is unchanged in both runs.
  def test_retention_drop_trips_the_gate
    base = write_report('leak-base', [[ALLOC_LABEL, 4210.0, 0.2], [RETENTION_LABEL, 1000.0, 0.0]])
    head = write_report('leak-head', [[ALLOC_LABEL, 4210.0, 0.2], [RETENTION_LABEL, 500.0, 0.0]])

    out, code = compare(base, head)

    assert_equal 1, code
    assert_includes out, "Regression: `#{RETENTION_LABEL}` -50.0%"
    assert_includes out, "| `#{ALLOC_LABEL}` | 4.21k | 4.21k | +0.0% | 🟢 |"
  end

  # Landing a new series must not fail its own PR: base predates the retention
  # line, so it is only_head (reported, never gated) rather than only_base.
  def test_new_series_on_head_is_reported_not_gated
    base = write_runs(ALLOC_LABEL, [4210.0, 0.2])
    head = write_report('new-series', [[ALLOC_LABEL, 4210.0, 0.2], [RETENTION_LABEL, 1000.0, 0.0]])

    out, code = compare(base, head)

    assert_equal 0, code
    assert_includes out, "_New on head: #{RETENTION_LABEL}_"
    refute_includes out, 'Missing on head'
  end
end
