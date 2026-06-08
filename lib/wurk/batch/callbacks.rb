# frozen_string_literal: true

require 'json'

module Wurk
  class Batch
    # Fires batch callbacks (`:success`, `:complete`, `:death`) by enqueuing
    # them as ordinary jobs on the batch's `callback_queue`. Dedup is via
    # b-<bid>-notify so the same callback can't be enqueued twice even
    # if multiple workers race to ack the final job.
    #
    # Callback wrapper job: Wurk::Batch::CallbackJob — given a target spec
    # ("Klass" or "Klass#method") and options hash, it instantiates and
    # invokes on_<event> (or the named method) with the Status snapshot.
    module Callbacks
      module_function

      # Called from the server middleware after BATCH_ACK_SUCCESS. Fires
      # `:complete` when live jids hit 0; fires `:success` when pending
      # also hits 0 and there have been no deaths.
      def maybe_fire(bid, pending:, live:)
        return unless live.zero?

        fire_complete(bid)
        fire_success(bid) if pending.zero? && !death_fired?(bid)
        propagate_to_parent(bid)
      end

      # Fired from Wurk::Batch::DeathHandler on the FIRST permanent death
      # in the batch only. Subsequent deaths bump the counter but do not
      # re-enqueue the callback.
      def fire_death(bid)
        return unless dedup_set(bid, 'death')

        record_event(bid, 'death_at')
        Wurk.redis { |conn| conn.call('ZADD', 'dead-batches', Time.now.to_f.to_s, bid) }
        enqueue_callbacks(bid, 'death')
        cascade_death(bid)
      end

      # A child's death means the parent — and every ancestor — can never
      # fully succeed, so `:death` propagates up the parent chain. The
      # recursion bottoms out at the root (empty parent_bid); fire_death's own
      # dedup_set guard makes each ancestor's `:death` fire exactly once even
      # under racing children.
      def cascade_death(bid)
        parent_bid = parent_bid_for(bid)
        return if parent_bid.nil? || parent_bid.empty?

        fire_death(parent_bid)
      end

      def fire_complete(bid)
        return unless dedup_set(bid, 'complete')

        record_event(bid, 'complete_at')
        enqueue_callbacks(bid, 'complete')
      end

      def fire_success(bid)
        return unless dedup_set(bid, 'success')

        record_event(bid, 'success_at')
        emit_duration_metric(bid)
        enqueue_callbacks(bid, 'success')
        apply_linger(bid)
      end

      # Pro statsd metric (spec §9.3): wall-clock seconds from batch creation to
      # full success. `created_at` shares the CLOCK_REALTIME epoch we record it
      # with. No-op without a dogstatsd client.
      #
      # Strictly best-effort: `fire_success` has already burned the `success`
      # dedup key by the time we run, so a raise here (e.g. a Redis hiccup on the
      # HGET) would permanently strand the success callbacks and linger that
      # follow — a retry can't re-fire them. Swallow and log instead.
      def emit_duration_metric(bid)
        created = Wurk.redis { |conn| conn.call('HGET', "b-#{bid}", 'created_at') }
        return if created.nil? || created.to_s.empty?

        seconds = ::Process.clock_gettime(::Process::CLOCK_REALTIME) - created.to_f
        Wurk::Metrics::Statsd.distribution('batch.duration_dist', seconds)
      rescue StandardError => e
        Wurk.logger.warn("batch #{bid}: duration metric emit failed: #{e.class}: #{e.message}")
        nil
      end

      # Post-success retention: a succeeded batch no longer coordinates any
      # jobs, so its keys expire after the per-batch `linger` override (else
      # 24h) instead of the 30d pending TTL. Mirrors Sidekiq Pro §2.8.
      def apply_linger(bid)
        raw     = Wurk.redis { |conn| conn.call('HGET', "b-#{bid}", 'linger') }
        seconds = raw.nil? || raw.to_s.empty? ? Batch::POST_SUCCESS_EXPIRY_SECONDS : raw.to_i
        Wurk.redis do |conn|
          Batch.keys_for(bid).each { |key| conn.call('EXPIRE', key, seconds) }
        end
      end

      # Atomically marks `bid` as having fired `event`. Returns true the
      # first time, false thereafter — caller skips the enqueue when false.
      # SET NX makes this safe under racing acks.
      def dedup_set(bid, event)
        Wurk.redis do |conn|
          ok = conn.call('SET', "b-#{bid}-#{event}", '1', 'NX', 'EX', Batch::CALLBACK_NOTIFY_TTL)
          ok == 'OK'
        end
      end

      def record_event(bid, field)
        now = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
        Wurk.redis do |conn|
          conn.call('HSET', "b-#{bid}", field, now.to_s)
          conn.call('HSET', "b-#{bid}", field.to_s.sub('_at', ''), '1')
        end
      end

      # True once `:death` has fired for this batch — from one of its own
      # jobs dying or from a descendant's death cascading up. Suppresses
      # `:success`, which must never fire after any death in the subtree.
      #
      # Reads the durable `death` field on `b-<bid>` (written by `record_event`),
      # not the `b-<bid>-death` dedup key — the dedup key has its own 30d TTL
      # and can expire while an ancestor batch is still open, after which a
      # late `maybe_fire` would wrongly emit `:success`.
      def death_fired?(bid)
        Wurk.redis { |conn| conn.call('HGET', "b-#{bid}", 'death') } == '1'
      end

      # Per-callback rescue: one bad spec or a transient enqueue failure must
      # not strand the batch with the remaining callbacks for this event
      # un-enqueued. Log and move on so every other callback still fires.
      def enqueue_callbacks(bid, event)
        callbacks, queue = callback_specs_for(bid)

        callbacks.each do |(cb_event, target, options)|
          next unless cb_event == event

          enqueue_callback_job(bid, target, event, options, queue)
        rescue StandardError => e
          Wurk.logger.warn("batch #{bid}: #{event} callback #{target.inspect} enqueue failed: #{e.class}: #{e.message}")
        end
      end

      def callback_specs_for(bid)
        raw = Wurk.redis { |conn| conn.call('HMGET', "b-#{bid}", 'callbacks', 'callback_queue') }
        callbacks_json, queue = raw
        queue = 'default' if queue.nil? || queue.empty?
        parsed = parse_callbacks(callbacks_json)
        [parsed, queue]
      end

      def parse_callbacks(raw)
        return [] if raw.nil? || raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        []
      end

      def enqueue_callback_job(bid, target, event, options, queue)
        Wurk::Client.push(
          'class' => 'Wurk::Batch::CallbackJob',
          'args' => [bid, target, event, options],
          'queue' => queue,
          'retry' => true
        )
      end

      # When a child batch's `:success` fires, decrement the parent's pkids
      # set so the parent's own `:success` waits on the full subtree. When
      # parent's pkids hits 0 *and* its own pending is 0, parent's success
      # fires too.
      def propagate_to_parent(bid)
        parent_bid = parent_bid_for(bid)
        return if parent_bid.nil? || parent_bid.empty?
        return unless pkids_drained?(parent_bid, bid)

        maybe_fire(parent_bid, pending: pending_for(parent_bid), live: live_for(parent_bid))
      end

      def parent_bid_for(bid)
        Wurk.redis { |conn| conn.call('HGET', "b-#{bid}", 'parent_bid') }
      end

      def pkids_drained?(parent_bid, child_bid)
        Wurk.redis do |conn|
          conn.call('SREM', "b-#{parent_bid}-pkids", child_bid)
          conn.call('SCARD', "b-#{parent_bid}-pkids").to_i.zero?
        end
      end

      def pending_for(bid) = Wurk.redis { |conn| conn.call('HGET', "b-#{bid}", 'pending') }.to_i
      def live_for(bid)    = Wurk.redis { |conn| conn.call('SCARD', "b-#{bid}-jids") }.to_i
    end
  end
end
