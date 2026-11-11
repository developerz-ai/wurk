# frozen_string_literal: true

module Wurk
  class Swarm
    # MAXMEM recycling (Ent §7.5): every CHECK_INTERVAL the supervisor reads
    # each child's memory and hands one over the limit to the restart machine
    # (`recycle`), which replaces it gracefully.
    #
    # A child already over the limit while still FRESH is never recycled: its
    # replacement would boot to the same size and be recycled in turn, a fork
    # loop that replaces a slot every few seconds and drains nothing useful.
    # Such a child is marked for the rest of its life and the limit reported
    # once per slot index at ERROR — the setting is below what a booted child
    # needs. A child that crosses the limit only after FRESH seconds is recycled
    # as before; if its replacement is over within its own fresh window, the
    # replacement is the one marked, so a slot recycles at most once per cause.
    #
    # The metric is `memory_limit_metric`: `:rss` from /proc/<pid>/statm (Ent's
    # meaning; counts pages still shared with the parent), `:pss`/`:uss` from
    # /proc/<pid>/smaps_rollup. Without /proc nothing is read and nothing is
    # recycled; `warn_if_unreadable` says so at boot.
    class MemoryWatch
      CHECK_INTERVAL = 10
      FRESH = Backoff::RESET_AFTER
      SMAPS_FIELDS = { pss: %w[Pss], uss: %w[Private_Clean Private_Dirty] }.freeze

      def initialize(limit_kb:, metric:, logger:, recycle:, interval: CHECK_INTERVAL, fresh: FRESH,
                     proc_root: '/proc', now: -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) })
        @limit_kb = limit_kb
        @metric = metric
        @logger = logger
        @recycle = recycle
        @interval = interval
        @fresh = fresh
        @now = now
        @proc_root = proc_root
        @last_check = nil
        @marked = {}
        @reported_slots = {}
      end

      # `children` is `{ pid => [seconds since fork, slot index] }`.
      def tick(children)
        now = @now.call
        return if @last_check && now - @last_check < @interval

        @last_check = now
        children.each { |pid, (age, slot)| check(pid, age, slot) }
      end

      def forget(pid)
        @marked.delete(pid)
      end

      def warn_if_unreadable
        return if read_kb(::Process.pid)

        @logger.warn do
          "swarm: memory_limit_mb is set but this host has no /proc #{source} to read #{@metric} from; " \
            'children will not be recycled'
        end
      end

      private

      def check(pid, age, slot)
        return if @marked.key?(pid)

        size_kb = read_kb(pid)
        return if size_kb.nil? || size_kb < @limit_kb
        return mark(pid, size_kb, age, slot) if age < @fresh

        @logger.warn do
          "swarm: child #{pid} (slot #{slot}) #{@metric.upcase} #{size_kb}KB >= #{@limit_kb}KB " \
            "#{age.round}s after boot; recycling"
        end
        @recycle.call(pid)
      end

      def mark(pid, size_kb, age, slot)
        @marked[pid] = true
        return if @reported_slots.key?(slot)

        @reported_slots[slot] = true
        @logger.error do
          "swarm: child #{pid} (slot #{slot}) is #{size_kb}KB #{@metric.upcase} #{age.round}s after boot, " \
            "already over memory_limit_mb (#{@limit_kb / 1024} MB). Recycling it would only fork another " \
            'child as large, so it is not recycled. Raise the limit above what a booted child uses, or ' \
            'compare against memory_limit_metric :pss. Reported once per slot.'
        end
      end

      def source = @metric == :rss ? 'statm' : 'smaps_rollup'

      def read_kb(pid)
        @metric == :rss ? statm_kb(pid) : smaps_kb(pid)
      rescue ::SystemCallError, ::IOError
        nil
      end

      def statm_kb(pid)
        Heartbeat.statm_rss_kb(::File.read("#{@proc_root}/#{pid}/statm"))
      end

      def smaps_kb(pid)
        fields = SMAPS_FIELDS.fetch(@metric)
        total = nil
        ::File.foreach("#{@proc_root}/#{pid}/smaps_rollup") do |line|
          name, value = line.split(':', 2)
          total = total.to_i + value.to_i if value && fields.include?(name)
        end
        total
      end
    end
  end
end
