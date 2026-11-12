# frozen_string_literal: true

require_relative 'histogram'
require_relative 'pool_registry'
require_relative 'process_counters'

module Wurk
  module Metrics
    # The `/metrics` families read from this process's memory rather than
    # Redis: ProcessCounters, the Redis pool gauges, the per-class duration
    # histograms, and (inside a swarm child) the parent's restart counters.
    # Under a swarm these describe the child that owns the health port, except
    # the restart counters, which are the parent's own.
    module ProcessFamilies
      extend Exposition

      # Per-class duration series beyond this many classes (by volume) fold into
      # `class="other"`, so a scrape stays bounded however many classes run.
      HISTOGRAM_CLASSES = 20
      HISTOGRAM_LE = Histogram::BUCKET_INTERVALS.map { |ms| ms >= 1e20 ? '+Inf' : (ms / 1000.0).to_s }.freeze
      COUNTERS = [
        ['wurk_fetch_errors_total', 'Fetch-loop errors in the process serving this scrape.', :fetch_errors],
        ['wurk_reaper_reclaimed_total', 'Orphaned jobs reclaimed by the process serving this scrape.',
         :reaper_reclaimed],
        ['wurk_poison_kills_total', 'Jobs sent to the dead set for being orphaned too often.', :poison_kills],
        ['wurk_leader_acquired_total', 'Times the process serving this scrape became leader.', :leader_acquired],
        ['wurk_client_buffer_dropped_total', 'Jobs dropped from the reliable_push outage buffer.', :client_buffer_drops]
      ].freeze
      RESTART_REASONS = %i[crash recycle liveness rolling].freeze

      class << self
        # `swarm` is a Swarm::RestartCounters::Snapshot, nil outside a swarm child.
        def render(out, swarm: nil)
          counters(out)
          scheduler(out)
          redis_pools(out)
          job_durations(out)
          swarm_restarts(out, swarm) if swarm
          out
        end

        private

        # `reaper_reclaimed` counts every OrphanReclaim move in this process;
        # the Reaper's share is counted on its own, so the rest is SelfReconcile.
        def counters(out)
          COUNTERS.each { |name, help, key| counter(out, name, help, ProcessCounters.value(key)) }
          by_reaper = ProcessCounters.value(:reaper_drained)
          by_self = [ProcessCounters.value(:reaper_reclaimed) - by_reaper, 0].max
          family(out, 'wurk_jobs_reclaimed_total', 'Orphaned jobs reclaimed, by who found them.', 'counter',
                 [[{ 'source' => 'reaper' }, by_reaper], [{ 'source' => 'self' }, by_self]])
        end

        def scheduler(out)
          promoted = ProcessCounters.labelled(:scheduler_promoted)
          family(out, 'wurk_scheduler_promoted_total', 'Jobs this process promoted from the retry and schedule sets.',
                 'counter', Scheduled::SETS.map { |set| [{ 'set' => set }, promoted.fetch(set, 0)] })
        end

        def redis_pools(out)
          pools = PoolRegistry.live.sort_by { |pool| pool.name.to_s }
          checkout_timeouts(out, pools.map(&:name))
          gauge(out, 'wurk_redis_pool_size', 'Connections a Redis pool may open.',
                pools.map { |pool| [{ 'pool' => pool.name }, pool.size] })
          gauge(out, 'wurk_redis_pool_available', 'Redis pool slots free right now.',
                pools.map { |pool| [{ 'pool' => pool.name }, pool.available] })
        end

        def checkout_timeouts(out, names)
          timeouts = ProcessCounters.labelled(:pool_checkout_timeouts)
          family(out, 'wurk_redis_pool_checkout_timeouts_total', 'Redis pool checkouts that timed out.', 'counter',
                 (names | timeouts.keys).sort_by(&:to_s).map { |pool| [{ 'pool' => pool }, timeouts.fetch(pool, 0)] })
        end

        def job_durations(out)
          out << "# HELP wurk_job_duration_seconds Successful job run time per class, in this process.\n" \
                 "# TYPE wurk_job_duration_seconds histogram\n"
          capped_durations(History::ACCUMULATOR.lifetime).each do |klass, (count, ms, hist)|
            cumulative = 0
            hist.each_with_index do |n, i|
              sample(out, 'wurk_job_duration_seconds_bucket', { 'class' => klass, 'le' => HISTOGRAM_LE[i] },
                     cumulative += n)
            end
            sample(out, 'wurk_job_duration_seconds_sum', { 'class' => klass }, ms / 1000.0)
            sample(out, 'wurk_job_duration_seconds_count', { 'class' => klass }, count)
          end
        end

        # The HISTOGRAM_CLASSES busiest classes as they are, the rest summed
        # under `other`.
        def capped_durations(lifetime)
          ranked = lifetime.sort_by { |klass, (count, _, _)| [-count, klass.to_s] }
          kept = ranked.first(HISTOGRAM_CLASSES).to_h
          ranked.drop(HISTOGRAM_CLASSES).map(&:last).each do |counts|
            kept[Accumulator::OTHER] = merge_durations(kept[Accumulator::OTHER], counts)
          end
          kept
        end

        def merge_durations(into, counts)
          return counts unless into

          [into[0] + counts[0], into[1] + counts[1], into[2].zip(counts[2]).map(&:sum)]
        end

        def swarm_restarts(out, swarm)
          family(out, 'wurk_swarm_child_restarts_total', 'Children the swarm parent replaced, by reason.', 'counter',
                 RESTART_REASONS.map { |reason| [{ 'reason' => reason.to_s }, swarm.restarts.fetch(reason, 0)] })
          gauge(out, 'wurk_swarm_crash_streak', 'Longest run of young crashes across swarm slots; 0 when none.',
                [[nil, swarm.crash_streak]])
        end
      end
    end
  end
end
