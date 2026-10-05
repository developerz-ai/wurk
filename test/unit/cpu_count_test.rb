# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'

# R9: the default swarm size reads the container's CPU quota, not the host's
# cores. Every case runs against a fake cgroup tree in a tmpdir.
class CpuCountTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    super
    @root = Dir.mktmpdir('wurk-cgroup')
    @proc_cgroup = File.join(@root, 'proc-self-cgroup')
  end

  def teardown
    FileUtils.remove_entry(@root)
    super
  end

  def test_no_cgroup_files_falls_back_to_nprocessors
    assert_equal Wurk::CpuCount::Result.new(64, 'Etc.nprocessors'), detect(64)
  end

  def test_v2_quota_in_a_namespaced_container
    proc_cgroup("0::/\n")
    write('cpu.max', "200000 100000\n")

    assert_equal Wurk::CpuCount::Result.new(2, 'cgroup v2 cpu.max'), detect(64)
  end

  def test_v2_fractional_quota_rounds_up
    write('cpu.max', "150000 100000\n")

    assert_equal 2, detect(64).count
  end

  def test_v2_sub_cpu_quota_is_floored_at_one
    write('cpu.max', "50000 100000\n")

    assert_equal 1, detect(64).count
  end

  def test_v2_unlimited_is_nprocessors
    write('cpu.max', "max 100000\n")

    assert_equal Wurk::CpuCount::Result.new(8, 'Etc.nprocessors'), detect(8)
  end

  def test_quota_above_nprocessors_keeps_nprocessors
    write('cpu.max', "1600000 100000\n")

    assert_equal Wurk::CpuCount::Result.new(4, 'Etc.nprocessors'), detect(4)
  end

  # Not namespaced: the limit is under this process's own path, and a tighter
  # one on an ancestor slice binds it too.
  def test_v2_reads_the_own_path_and_takes_the_tightest_ancestor
    proc_cgroup("0::/kubepods.slice/pod1/ctr\n")
    write('kubepods.slice/pod1/ctr/cpu.max', "400000 100000\n")
    write('kubepods.slice/pod1/cpu.max', "300000 100000\n")
    write('kubepods.slice/cpu.max', "max 100000\n")

    assert_equal 3, detect(64).count
  end

  def test_v2_ignores_garbage
    write('cpu.max', "lots 100000\n")

    assert_equal 'Etc.nprocessors', detect(16).source
  end

  def test_v1_cfs_quota
    write('cpu,cpuacct/cpu.cfs_quota_us', "250000\n")
    write('cpu,cpuacct/cpu.cfs_period_us', "100000\n")

    assert_equal Wurk::CpuCount::Result.new(3, 'cgroup v1 cpu.cfs_quota_us'), detect(64)
  end

  def test_v1_unlimited_quota
    write('cpu/cpu.cfs_quota_us', "-1\n")
    write('cpu/cpu.cfs_period_us', "100000\n")

    assert_equal 'Etc.nprocessors', detect(64).source
  end

  def test_v1_zero_period_is_ignored
    write('cpu/cpu.cfs_quota_us', "100000\n")
    write('cpu/cpu.cfs_period_us', "0\n")

    assert_equal 'Etc.nprocessors', detect(64).source
  end

  def test_the_real_host_answers_something_usable
    result = Wurk::CpuCount.detect

    assert_operator result.count, :>=, 1
    assert_operator result.count, :<=, Etc.nprocessors
  end

  private

  def detect(nprocessors)
    Wurk::CpuCount.detect(root: @root, proc_cgroup: @proc_cgroup, nprocessors: nprocessors)
  end

  def proc_cgroup(content)
    File.write(@proc_cgroup, content)
  end

  def write(rel, content)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
