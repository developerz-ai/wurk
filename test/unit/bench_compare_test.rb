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

  # benchmark/ips report line, as bin/bench-compare parses it.
  def ips_line(label, ips, err)
    format('%<label>s   %<ips>.1f (± %<err>.1f%%) i/s -    1.00k in   5.000s', label: label, ips: ips, err: err)
  end

  def write_runs(label, *runs)
    path = File.join(@dir, "#{label.gsub(/\W+/, '_')}_#{object_id}_#{runs.hash.abs}.txt")
    File.write(path, runs.map { |ips, err| ips_line(label, ips, err) }.join("\n") << "\n")
    path
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
end
