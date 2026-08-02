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

      # Called from the server middleware after BATCH_ACK_SUCCESS (and from
      # DeathHandler when a death drains the last live jid). Fires `:complete`
      # when live jids hit 0; fires `:success` when pending also hits 0 and
      # there have been no deaths.
      #
      # Both fires are additionally gated on `b-<bid>-pkids` being empty —
      # children whose own subtree hasn't finished yet (#209). Spec §2.4:
      # child `:complete`/`:success` fire before the parent's, so when the
      # parent's *own* last job acks while a child batch is still running,
      # nothing fires here; the last child's propagate_to_parent re-invokes
      # this and fires then. The SREM in pkids_drained? happens before that
      # re-invocation, so exactly one of the racing paths fires (dedup_set
      # absorbs the overlap).
      def maybe_fire(bid, pending:, live:)
        return unless live.zero?
        return unless kids_finished?(bid)

        fire_complete(bid)
        fire_success(bid) if pending.zero? && !subtree_dead?(bid)
        propagate_to_parent(bid)
      end

      def kids_finished?(bid)
        Wurk.redis { |conn| conn.call('SCARD', "b-#{bid}-pkids") }.to_i.zero?
      end

      # Fired from Wurk::Batch::DeathHandler whenever a death makes the died
      # set go non-empty: the first death, or the first re-death after every
      # dead jid was manually retried back into the live set (#212 — that
      # retry's BATCH_PUSH cleared the death mark). The mark — durable `death`
      # flag, `death_at`, `dead-batches` membership — is (re-)applied before
      # the dedup guard so it is restored on re-death; the callback enqueue
      # and parent cascade stay behind the guard so `:death` is enqueued at
      # most once per batch.
      def fire_death(bid)
        record_event(bid, 'death_at')
        Wurk.redis { |conn| conn.call('ZADD', 'dead-batches', Time.now.to_f.to_s, bid) }
        return unless dedup_set(bid, 'death')

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

      # The HSETs resurrect the hash when a callback fires for a batch whose keys
      # already expired (a child batch outliving its parent's 30d window), so the
      # write is followed by an NX stamp — without it the resurrected hash would
      # have no clock at all. NX leaves a live batch's expiry, and the shorter
      # post-success `linger` window, untouched.
      def record_event(bid, field)
        now = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
        Wurk.redis do |conn|
          conn.call('HSET', "b-#{bid}", field, now.to_s)
          conn.call('HSET', "b-#{bid}", field.to_s.sub('_at', ''), '1')
          conn.call('EXPIRE', "b-#{bid}", Batch::DEFAULT_EXPIRY_SECONDS, 'NX')
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

      # A batch's subtree is still dead while it carries the durable death
      # mark OR any direct child does — deaths cascade up the parent chain,
      # so a dead descendant keeps every ancestor's child marked. This gates
      # `:success`, which must never fire while a job in the subtree is
      # terminally dead (spec §2.4). The child check matters for the brief
      # window where a batch with both its own dead job and a dead child has
      # its OWN dead job retried to success: BATCH_PUSH (#212) clears that
      # batch's own mark when its died set drains, but the child subtree is
      # still dead, so `death_fired?` alone would wrongly let `:success` fire.
      def subtree_dead?(bid)
        death_fired?(bid) || any_child_dead?(bid)
      end

      # Recovery counterpart to cascade_death (#226). When a descendant's
      # last dead job is manually retried back to success, the descendant
      # clears its OWN death mark (#212, in BATCH_PUSH) — but every ancestor
      # was marked by the death *cascade*, not by a jid in its own died set,
      # so nothing here ever cleared them and the ancestor's `:success`
      # stayed suppressed forever. Re-evaluate this batch: drop its durable
      # death mark and `dead-batches` membership once its own died set is
      # empty AND no child still carries a death mark. The `b-<bid>-death`
      # notify dedup key is deliberately left intact, so a later re-death
      # re-marks the batch (fire_death restores the flag before its own
      # dedup guard) without ever re-enqueuing `:death`.
      def clear_death_on_recovery(bid)
        return unless death_fired?(bid)
        return if own_died_remaining?(bid)
        return if any_child_dead?(bid)

        Wurk.redis do |conn|
          conn.call('HDEL', "b-#{bid}", 'death')
          conn.call('ZREM', 'dead-batches', bid)
        end
      end

      def own_died_remaining?(bid)
        Wurk.redis { |conn| conn.call('SCARD', "b-#{bid}-died") }.to_i.positive?
      end

      def any_child_dead?(bid)
        kids = Wurk.redis { |conn| conn.call('SMEMBERS', "b-#{bid}-kids") }
        kids.any? { |kid| death_fired?(kid) }
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

      # When a child batch finishes (its live jids hit 0 — by success or
      # death), remove it from the parent's pkids set so the parent's own
      # callbacks wait on the full subtree. When the parent's pkids hits 0,
      # re-run the parent's maybe_fire: if its own counts are already at
      # zero (the parent-acks-first race), this is what finally fires it.
      def propagate_to_parent(bid)
        parent_bid = parent_bid_for(bid)
        return if parent_bid.nil? || parent_bid.empty?
        return unless pkids_drained?(parent_bid, bid)

        # A recovered child may have lifted the last death from the parent's
        # subtree — clear the parent's cascaded mark before its gate runs, so
        # `:success` can fire. Harmless on the death path: the dying child
        # still carries its mark, so any_child_dead? keeps the parent dead.
        clear_death_on_recovery(parent_bid)
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
