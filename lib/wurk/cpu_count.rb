# frozen_string_literal: true

require 'etc'

module Wurk
  # How many CPUs this process may actually use — the default swarm size.
  #
  # `Etc.nprocessors` reports the host's cores (or the affinity mask), not the
  # container's share of them: a pod limited to 2 CPUs on a 64-core node reads
  # 64, and a swarm that forks one child per core then runs 64 processes on 2
  # CPUs' worth of CFS quota — throttled, with 32x the memory. The quota lives
  # in the cgroup, so it is read from there and the smaller of the two wins.
  #
  # cgroup v2: `cpu.max` is `<quota> <period>` or `max <period>`, read in this
  # process's own cgroup and every ancestor up to the mount root (a limit set on
  # a parent slice binds the child too), smallest wins. cgroup v1:
  # `cpu.cfs_quota_us` (-1 = unlimited) over `cpu.cfs_period_us`, in the cpu
  # controller's mount. Either way `ceil(quota / period)`, floored at 1: a
  # 1.5-CPU quota can keep two processes busy part of the time, and rounding a
  # 0.5-CPU quota down to zero would fork nothing.
  module CpuCount
    Result = Data.define(:count, :source)

    ROOT = '/sys/fs/cgroup'
    PROC_SELF_CGROUP = '/proc/self/cgroup'
    V1_CONTROLLER_DIRS = %w[cpu cpu,cpuacct cpuacct,cpu].freeze

    module_function

    def detect(root: ROOT, proc_cgroup: PROC_SELF_CGROUP, nprocessors: Etc.nprocessors)
      quota = cgroup_v2_quota(root, proc_cgroup)
      source = 'cgroup v2 cpu.max'
      unless quota
        quota = cgroup_v1_quota(root)
        source = 'cgroup v1 cpu.cfs_quota_us'
      end
      return Result.new(nprocessors, 'Etc.nprocessors') if quota.nil? || quota >= nprocessors

      Result.new(quota, source)
    end

    def cgroup_v2_quota(root, proc_cgroup)
      v2_dirs(root, proc_cgroup).filter_map { |dir| v2_limit(File.join(dir, 'cpu.max')) }.min
    end

    # `0::<path>` is the v2 entry. Inside a container with its own cgroup
    # namespace the path is `/` and the limit sits at the mount root; on a host
    # (or without the namespace) it sits under the full path.
    def v2_dirs(root, proc_cgroup)
      line = read(proc_cgroup)&.lines&.find { |l| l.start_with?('0::') }
      path = line ? line.strip.delete_prefix('0::') : '/'
      dirs = []
      loop do
        dirs << File.join(root, path)
        break if path == '/' || path.empty?

        path = File.dirname(path)
      end
      dirs.uniq
    end

    def v2_limit(file)
      quota, period = read(file)&.split
      return nil if quota.nil? || quota == 'max'

      ceil_ratio(quota, period)
    end

    def cgroup_v1_quota(root)
      V1_CONTROLLER_DIRS.each do |dir|
        quota = read(File.join(root, dir, 'cpu.cfs_quota_us'))
        next unless quota

        return nil if quota.strip.start_with?('-')

        return ceil_ratio(quota, read(File.join(root, dir, 'cpu.cfs_period_us')))
      end
      nil
    end

    def ceil_ratio(quota, period)
      quota = Integer(quota.to_s.strip, 10)
      period = Integer(period.to_s.strip, 10)
      return nil unless quota.positive? && period.positive?

      (quota + period - 1) / period
    rescue ArgumentError
      nil
    end

    def read(path)
      File.read(path)
    rescue SystemCallError, IOError
      nil
    end
  end
end
