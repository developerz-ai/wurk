# frozen_string_literal: true

require_relative '../limiter'
require_relative '../cron'
require_relative '../client'
require_relative '../metrics/query'

module Wurk
  class Web
    # Web UI Ent-feature surface (spec: docs/target/sidekiq-ent.md §9.1).
    # Each tab — Limits, Periodic, Historical — gets a small helper module
    # that the API controller delegates to. The data fabric lives here so
    # the controller stays a thin JSON shim and so library users wanting
    # the same operations programmatically (cron management scripts,
    # operator REPL, etc.) have a single entry point.
    #
    # Wurk ships these free; no license gate, no env flag.
    module Enterprise
      # Limits tab — list every registered limiter, filter by name, expose
      # reset + delete. List/metrics already render via `Wurk::Limiter::Base`;
      # this wrapper adds the name filter documented in §1.2.0+.
      module Limits
        module_function

        # @return [Array<String>] limiter names, optionally filtered to those
        #   whose name contains the case-insensitive substring `filter`.
        def list(filter: nil)
          names = Wurk.redis { |c| c.call('SMEMBERS', Wurk::Limiter::LIST_KEY) }.sort
          return names if filter.nil? || filter.to_s.empty?

          needle = filter.to_s.downcase
          names.select { |n| n.downcase.include?(needle) }
        end

        def metadata(name)
          raw = Wurk.redis { |c| c.call('HGETALL', "lmtr:#{name}") }
          raw.is_a?(Array) ? raw.each_slice(2).to_h : raw
        end

        # Stats-key reset: drops every `lmtr-stats:` / state key for the
        # named limiter while keeping its metadata + LIST membership so the
        # row remains in the UI. Mirrors the §1.5 `#reset` surface — the
        # name is wire-compat, so the trailing-? rule doesn't apply here.
        def reset(name) # rubocop:disable Naming/PredicateMethod
          Wurk.redis do |c|
            %W[lmtr-cs:#{name} lmtr-b:#{name} lmtr-w:#{name} lmtr-l:#{name}
               lmtr-p:#{name} lmtr-stats:#{name}].each { |k| c.call('DEL', k) }
          end
          true
        end
      end

      # Periodic tab — list/pause/unpause/enqueue-now/history. The list view
      # reuses `Wurk::Cron::LoopSet`; mutating actions write directly to the
      # `loops:{lid}` HASH so they're idempotent and crash-safe.
      module Periodic
        module_function

        def list
          Wurk::Cron::LoopSet.new
        end

        def fetch(lid)
          Wurk::Cron::LoopSet.new.fetch(lid)
        end

        def pause(lid)
          set_paused(lid, '1')
        end

        def unpause(lid)
          set_paused(lid, '0')
        end

        # Spec §2.4 "enqueue-now": pushes a one-off run with the loop's
        # configured klass/queue/args/retry. Returns the new jid, or nil
        # when the loop doesn't exist.
        def enqueue_now(lid)
          loop_obj = fetch(lid)
          return nil unless loop_obj

          Wurk::Client.new.push(
            'class' => loop_obj.klass,
            'args' => loop_obj.args,
            'queue' => loop_obj.queue,
            'retry' => loop_obj.retry_value
          )
        end

        # Spec §8.0.1+: per-loop history list at `loop-history:{lid}`. Each
        # entry is a `[fired_at, jid]` tuple (LPUSH'd by the poller).
        def history(lid)
          loop_obj = fetch(lid)
          return [] unless loop_obj

          loop_obj.history
        end

        def set_paused(lid, value) # rubocop:disable Naming/PredicateMethod
          loop_obj = fetch(lid)
          return false unless loop_obj

          Wurk.redis { |c| c.call('HSET', "#{Wurk::Cron::LOOP_PREFIX}#{lid}", 'paused', value) }
          true
        end
      end

      # Historical tab — per-class and per-queue gauges over a recent window.
      # The minute / hour HASH layout comes from `Wurk::Metrics::History`;
      # `Query.for_job` / `Query.top_jobs` already does the fan-out. The
      # wrapper here is a stable entry point so the controller doesn't reach
      # into the `Query` module directly (and so we have one place to layer
      # additional aggregations on later — global gauges across all classes).
      module Historical
        module_function

        # Per-class time series. Pass exactly one of `minutes:` / `hours:`.
        # Returns `[{at: Time, p:, f:, ms:}, …]` ordered oldest→newest.
        def for_job(klass, minutes: nil, hours: nil, now: ::Time.now)
          Wurk::Metrics::Query.for_job(klass, minutes: minutes, hours: hours, now: now)
        end

        # Global top-N rollup. Wraps `Query.top_jobs` and keeps the wire
        # shape of `[[class_name, {p:, f:, ms:}], ...]`.
        def top(minutes: 60, class_filter: nil)
          Wurk::Metrics::Query.top_jobs(minutes: minutes, class_filter: class_filter)
        end

        # Cluster-total time-series for the dashboard charts. `bucket` is
        # '1m'/'5m'/'1h'; `window` is in seconds (clamped to the bucket's
        # retention). Returns `[{at:, p:, f:, ms:}, …]` oldest→newest.
        def history(bucket, window:, now: ::Time.now)
          Wurk::Metrics::Query.history(bucket, window, now: now)
        end

        # Per-queue size/latency gauge time-series for the Historical tab.
        # `bucket` is '1m'/'5m'/'1h'; `window` is in seconds (clamped to the
        # bucket's retention). `queues:` narrows to one queue (else every live
        # queue). Returns `[{name:, points: [{at:, size:, latency:}, …]}, …]`.
        def queue_history(bucket, window:, queues: nil, now: ::Time.now)
          Wurk::Metrics::Query.queue_history(bucket, window, queues: queues, now: now)
        end

        # Ent §5.3 Historical snapshots from the `history:metrics` stream,
        # oldest→newest. Returns `[{at:, processed:, failures:, …}, …]`.
        def snapshots(limit: Wurk::History::STREAM_DEFAULT_LIMIT)
          Wurk::History.recent(limit: limit)
        end
      end
    end
  end
end
