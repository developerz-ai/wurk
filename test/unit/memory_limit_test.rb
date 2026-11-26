# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'

# The Busy page shows RSS against the container's memory limit, not the
# node's RAM. Every case runs against a fake cgroup tree in a tmpdir.
class MemoryLimitTest < Wurk::Test::UnitCase
  parallelize_me!

  GIB = 1024**3

  def setup
    super
    @root = Dir.mktmpdir('wurk-cgroup')
    @proc_cgroup = File.join(@root, 'proc-self-cgroup')
  end

  def teardown
    FileUtils.remove_entry(@root)
    super
  end

  def test_no_cgroup_files_is_unlimited
    assert_nil detect
  end

  def test_v2_limit_in_a_namespaced_container
    proc_cgroup("0::/\n")
    write('memory.max', "#{2 * GIB}\n")

    assert_equal 2 * GIB, detect
  end

  def test_v2_max_is_unlimited
    write('memory.max', "max\n")

    assert_nil detect
  end

  def test_v2_takes_the_tightest_ancestor
    proc_cgroup("0::/kubepods.slice/pod1/ctr\n")
    write('kubepods.slice/pod1/ctr/memory.max', "max\n")
    write('kubepods.slice/pod1/memory.max', "#{3 * GIB}\n")
    write('kubepods.slice/memory.max', "#{60 * GIB}\n")

    assert_equal 3 * GIB, detect
  end

  def test_v2_ignores_garbage
    write('memory.max', "lots\n")

    assert_nil detect
  end

  def test_v1_limit
    write('memory/memory.limit_in_bytes', "#{GIB}\n")

    assert_equal GIB, detect
  end

  # v1 spells "unlimited" as LONG_MAX rounded down to a page.
  def test_v1_unlimited_sentinel
    write('memory/memory.limit_in_bytes', "9223372036854771712\n")

    assert_nil detect
  end

  def test_v2_wins_over_v1
    write('memory.max', "#{GIB}\n")
    write('memory/memory.limit_in_bytes', "#{2 * GIB}\n")

    assert_equal GIB, detect
  end

  def test_the_real_host_answers_without_raising
    result = Wurk::MemoryLimit.detect

    assert(result.nil? || result.positive?)
  end

  private

  def detect
    Wurk::MemoryLimit.detect(root: @root, proc_cgroup: @proc_cgroup)
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
