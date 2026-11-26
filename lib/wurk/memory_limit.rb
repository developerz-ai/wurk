# frozen_string_literal: true

require_relative 'cpu_count'

module Wurk
  # The memory this process's cgroup may use, in bytes, or nil when nothing
  # caps it. `/proc/meminfo` inside a container reports the node's RAM, so a
  # pod limited to 2 GiB on a 64 GiB node reads 64 GiB there; the Busy page
  # shows RSS against this instead.
  #
  # cgroup v2: `memory.max` (`max` = unlimited) in this process's own cgroup
  # and every ancestor, tightest wins (the same walk as {CpuCount}). cgroup v1:
  # `memory.limit_in_bytes` in the memory controller's mount, where
  # "unlimited" is a page-rounded LONG_MAX; anything at or above
  # {V1_UNLIMITED} counts as no limit, and the caller also drops a limit at or
  # above the host's RAM.
  module MemoryLimit
    V1_UNLIMITED = 2**62

    module_function

    def detect(root: CpuCount::ROOT, proc_cgroup: CpuCount::PROC_SELF_CGROUP)
      cgroup_v2(root, proc_cgroup) || cgroup_v1(root)
    end

    def cgroup_v2(root, proc_cgroup)
      CpuCount.v2_dirs(root, proc_cgroup).filter_map { |dir| bytes(CpuCount.read(File.join(dir, 'memory.max'))) }.min
    end

    def cgroup_v1(root)
      limit = bytes(CpuCount.read(File.join(root, 'memory', 'memory.limit_in_bytes')))
      limit if limit && limit < V1_UNLIMITED
    end

    def bytes(raw)
      value = Integer(raw.to_s.strip, 10)
      value if value.positive?
    rescue ArgumentError
      nil
    end
  end
end
