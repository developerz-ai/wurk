# frozen_string_literal: true

require 'json'
require_relative '../middleware'
require_relative '../metrics/statsd'
require_relative '../keys'
require_relative '../dead_set'

module Wurk
  module Middleware
    # Pro parity (§3.2): poison-pill detection for reliable-fetch orphans.
    # When a job is recovered out of a dead process's private list, we
    # INCR a per-jid counter at `super_fetch:recovered:<jid>` with a 72h
    # TTL. Once the counter crosses RECOVERY_THRESHOLD (3) the next recovery
    # is treated as a poison pill: the payload is moved to the dead set,
    # `jobs.poison` is emitted to statsd, and recovery callbacks fire so
    # operators can be paged.
    #
    # Counter key TTL is wire-compat with Sidekiq Pro — third-party tooling
    # that watches `super_fetch:recovered:*` expects 72h.
    #
    # No server-middleware registration: callers are reaper / bulk_requeue
    # paths that drive the lifecycle directly via `track!(payload, queue:)`.
    # When that integration lands, it just calls `PoisonPill.track!` on each
    # orphan it about to RPUSH back to the public queue.
    module PoisonPill
      RECOVERY_THRESHOLD = 3
      RECOVERY_TTL = 72 * 60 * 60
      KEY_PREFIX = 'super_fetch:recovered:'
      DEAD_RECORD_LIMIT = 100

      # The `pill` handed to a Pro `super_fetch! { |jobstr, pill| }` recovery
      # callback on the kill path. Responds to .jid/.klass/.count/.queue so a
      # `pill.jid`-style Pro initializer drops in. `.count` shadows Struct#count
      # by design — Pro's API names it that. Spec: sidekiq-pro.md §3.1.
      Pill = ::Struct.new(:jid, :klass, :count, :queue, keyword_init: true) # rubocop:disable Lint/StructNewOverride

      module_function

      # Called per recovered orphan job. Returns `:poison` when the threshold
      # was crossed and the job was killed; `:recovered` when the job is
      # being re-pushed (caller's responsibility — we don't touch the queue
      # here). Emits `jobs.recovered.fetch` on every call, `jobs.poison`
      # only on the kill path.
      #
      # Fires the Pro `super_fetch!` recovery callback (config.super_fetch_callback)
      # exactly once per call: `(jobstr, nil)` on plain recovery, `(jobstr, pill)`
      # on the kill path. The poison-only `on_poison` Hash callbacks fire
      # independently inside #mark_poison.
      #
      # @param payload [String, Hash] the job JSON or pre-parsed hash.
      # @param queue   [String, nil] the public queue name (without `queue:`).
      # @param config  [Configuration] config that owns the super_fetch! callback;
      #   defaults to the global so non-reaper callers (tests) need not pass it.
      # @return [Symbol] :recovered | :poison
      def track!(payload, queue: nil, config: Wurk.configuration)
        job = parse(payload)
        unless job
          fire_super_fetch(config, payload, nil)
          return :recovered
        end

        jid = job['jid']
        klass = job['class']
        emit_recovered_fetch(klass, queue)

        count = bump_counter(jid) if jid && !jid.empty?
        if count && count >= RECOVERY_THRESHOLD
          mark_poison(payload, job, queue: queue, count: count)
          fire_super_fetch(config, payload, Pill.new(jid: jid, klass: klass, count: count, queue: queue))
          :poison
        else
          fire_super_fetch(config, payload, nil)
          :recovered
        end
      end

      # Reads the current recovery counter without bumping it. Used by tests
      # and dashboards; returns 0 for jobs that have never been recovered.
      def recovery_count(jid)
        return 0 if jid.nil? || jid.to_s.empty?

        Wurk.redis { |conn| conn.call('GET', "#{KEY_PREFIX}#{jid}") }.to_i
      end

      # Resets the counter for a jid — call after a successful perform so a
      # job that recovered twice and then completed doesn't accumulate state.
      def clear!(jid)
        return if jid.nil? || jid.to_s.empty?

        Wurk.redis { |conn| conn.call('DEL', "#{KEY_PREFIX}#{jid}") }
      end

      # Register a callback fired when a poison pill is detected. Callbacks
      # receive a single Hash `{jid:, klass:, count:, queue:}` — matches
      # Sidekiq Pro's documented shape so consumers can drop in unchanged.
      def on_poison(&block)
        raise ArgumentError, 'block required' unless block

        callbacks << block
        block
      end

      def callbacks
        @callbacks ||= []
      end

      # Test-only reset.
      def reset!
        @callbacks = []
      end

      # ---- internals --------------------------------------------------

      def parse(payload)
        case payload
        when Hash then payload
        when String
          begin
            Wurk.load_json(payload)
          rescue ::JSON::ParserError
            nil
          end
        end
      end

      # No apply-safety claim: INCR is additive, so a block replayed after a
      # lost reply bumps twice and can carry a healthy job past
      # RECOVERY_THRESHOLD into the dead set. Raising instead only leaves the
      # count short — Reaper#drain rescues, and the job is already back on its
      # public queue, so it just misses one poison check.
      def bump_counter(jid)
        key = "#{KEY_PREFIX}#{jid}"
        Wurk.redis do |conn|
          count = conn.call('INCR', key).to_i
          conn.call('EXPIRE', key, RECOVERY_TTL)
          count
        end
      end

      def emit_recovered_fetch(klass, queue)
        tags = []
        tags << "class:#{klass}" if klass
        tags << "queue:#{queue}" if queue
        Wurk::Metrics::Statsd.increment('jobs.recovered.fetch', tags: tags.empty? ? nil : tags)
      end

      def mark_poison(payload, job, queue:, count:)
        emit_poison(job['class'], queue)
        json = payload.is_a?(String) ? payload : Wurk.dump_json(job)
        Wurk::DeadSet.new.kill(json, notify_failure: false)
        fire_callbacks(jid: job['jid'], klass: job['class'], count: count, queue: queue)
      end

      def emit_poison(klass, queue)
        tags = []
        tags << "class:#{klass}" if klass
        tags << "queue:#{queue}" if queue
        Wurk::Metrics::Statsd.increment('jobs.poison', tags: tags.empty? ? nil : tags)
      end

      def fire_callbacks(pill)
        callbacks.each do |cb|
          cb.call(pill)
        rescue StandardError => e
          Wurk.configuration.handle_exception(e, context: 'Wurk::Middleware::PoisonPill')
        end
      end

      # Invoke the Pro recovery callback registered via config.super_fetch! { }.
      # No-op unless one is registered. `jobstr` is the raw job JSON so a Pro
      # `|jobstr, pill|` block sees exactly what Sidekiq Pro hands it.
      def fire_super_fetch(config, payload, pill)
        cb = config.super_fetch_callback
        return unless cb

        jobstr = payload.is_a?(::String) ? payload : Wurk.dump_json(payload)
        cb.call(jobstr, pill)
      rescue StandardError => e
        config.handle_exception(e, context: 'Wurk::Middleware::PoisonPill')
      end
    end
  end
end
