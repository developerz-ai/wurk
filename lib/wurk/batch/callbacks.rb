# frozen_string_literal: true

require 'json'
require_relative '../lua'

module Wurk
  class Batch
    # Raised by `Callbacks.enqueue_callbacks` once every callback for the event
    # has been attempted and at least one could not be enqueued, so the caller
    # leaves the event's dedup marker unwritten and the next fire retries it.
    class CallbackEnqueueError < StandardError; end

    # Fires batch callbacks (`:success`, `:complete`, `:death`) by enqueuing
    # them as ordinary jobs on the batch's `callback_queue`.
    #
    # Callback wrapper job: Wurk::Batch::CallbackJob — given a target spec
    # ("Klass" or "Klass#method") and options hash, it instantiates and
    # invokes on_<event> (or the named method) with the Status snapshot.
    #
    # A child batch's `:complete` and `:success` callback jobs are enqueued
    # *into its parent batch* (their payload carries the parent's `bid`), so
    # they are live jids of the parent: the parent cannot drain until they
    # have run. That is what makes the spec §2.9 step workflow work —
    # `step1_done` reopens the parent and adds `step2` before the parent can
    # fire. A callback job that fails counts against the parent like any of
    # its jobs (a death suppresses the parent's `:success`). `:death`
    # callbacks stay outside: they fire while the child is still running, and
    # a notification must not hold or poison the parent.
    module Callbacks
      module_function

      # In-process re-drive for the fire and ack paths. Nothing else re-drives
      # a fire once the job that drained the batch has acked, so a transient
      # Redis error there would otherwise strand the callbacks for good.
      REDRIVE_ATTEMPTS = 3
      REDRIVE_BACKOFF = 0.05

      # Runs on the post-state of a batch script that moved a member out of the
      # live jids or pending-children set (see the gate note heading
      # lua/batch_ack_success.lua). Fires `:complete` once both sets are empty, and
      # `:success` when pending is also 0 and nothing in the subtree is dead;
      # then hands the drain to the parent.
      #
      # Spec §2.4: child `:complete`/`:success` fire before the parent's, so a
      # parent whose own jobs are done while a child batch is still running
      # waits here (kids > 0); the child's `propagate_to_parent` re-enters with
      # the parent's fresh state when it finishes.
      def maybe_fire(bid, pending:, live:, kids:)
        return unless live.zero? && kids.zero?

        fire_complete(bid)
        fire_success(bid) if pending.zero? && !subtree_dead?(bid)
        propagate_to_parent(bid)
      end

      # Yields the attempt number (0-based) and retries a StandardError up to
      # REDRIVE_ATTEMPTS times in total, re-raising the last one. Every block
      # handed to it is idempotent: the ack scripts are SREM/SADD-guarded and
      # the fires are marker-guarded.
      def retrying(attempts: REDRIVE_ATTEMPTS)
        attempt = 0
        begin
          yield attempt
        rescue StandardError
          attempt += 1
          raise if attempt >= attempts

          sleep(REDRIVE_BACKOFF * attempt)
          retry
        end
      end

      # Fired from Wurk::Batch::DeathHandler whenever a death makes the died
      # set go non-empty: the first death, or the first re-death after every
      # dead jid was manually retried back into the live set (#212 — that
      # retry's BATCH_PUSH cleared the death mark). The mark — durable `death`
      # flag, `death_at`, `dead-batches` membership — is (re-)applied before
      # the dedup guard so it is restored on re-death; the callback enqueue
      # and parent cascade stay behind the guard so `:death` is enqueued at
      # most once per batch.
      #
      # That claim-before-enqueue ordering is kept deliberately, against the
      # enqueue-before-mark rule `fire_complete` explains: everything that
      # makes the batch *look* dead is already persisted above the guard, so a
      # crash in the window costs the notification while `Status`, the
      # dashboard and `subtree_dead?` all still see a dead batch. `:complete`
      # and `:success` have no such fallback — the callback is their whole
      # signal — and this claim additionally gates `cascade_death`, which
      # would otherwise re-walk the ancestor chain on every re-invocation. An
      # enqueue that *raises* is different from a crash: the claim is handed
      # back so the caller's re-drive fires `:death` again.
      def fire_death(bid)
        record_event(bid, 'death_at')
        index_dead(bid)
        return unless dedup_set(bid, 'death')

        begin
          enqueue_callbacks(bid, 'death')
        rescue CallbackEnqueueError
          Wurk.redis { |conn| conn.call('DEL', "b-#{bid}-death") }
          raise
        end
        cascade_death(bid)
      end

      # Index the batch as dead and bound the set in the same round trip. The
      # score stays `Time.now.to_f` (wire format, spec §2.8); `Batch.trim_index`
      # reads it as the epoch seconds it is. See there for why the set needs a
      # trim at all — only `Status#delete` and the death-recovery ZREM ever
      # remove a member, and neither runs for a batch left to expire.
      def index_dead(bid)
        Wurk.redis do |conn|
          conn.pipelined do |pipe|
            pipe.call('ZADD', 'dead-batches', Time.now.to_f.to_s, bid)
            Batch.trim_index(pipe, 'dead-batches')
          end
        end
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

      # `:complete` and `:success` mark their dedup key *after* the enqueue,
      # never before (F16): a claim-then-enqueue ordering turns a crash in
      # between into callbacks nobody ever enqueues. Enqueuing first makes the
      # durable side effect happen before the marker that suppresses it, and an
      # enqueue that raised leaves the marker unwritten so the re-drive (the
      # caller's `retrying`, or a reclaimed re-run of the draining job) fires
      # the event again.
      #
      # The accepted direction is a duplicate over a lost callback: callback
      # jobs retry like any other job and must already be idempotent (spec
      # §2.4, §12 "Callback retries"), so firing one twice is a cost the app
      # is required to absorb, while losing one silently strands the batch.
      # Concurrent duplicates are confined to re-drives: the fire gate admits
      # exactly one caller per drain transition.
      #
      # `record_event` stays ahead of the enqueue: the callback job reads a
      # Status snapshot and must see `complete_at`/`success_at` already set.
      def fire_complete(bid)
        return if dedup_marked?(bid, 'complete')

        record_event(bid, 'complete_at')
        enqueue_callbacks(bid, 'complete')
        dedup_set(bid, 'complete')
      end

      # Same enqueue-then-mark ordering as fire_complete. `apply_linger` runs
      # last of all: it EXPIREs `b-<bid>-success` down to the linger window,
      # which only holds if the marker already exists — `dedup_set`'s 30d
      # `EX` would otherwise re-create it outside that window.
      def fire_success(bid)
        return if dedup_marked?(bid, 'success')

        record_event(bid, 'success_at')
        emit_duration_metric(bid)
        enqueue_callbacks(bid, 'success')
        dedup_set(bid, 'success')
        apply_linger(bid)
      end

      # Pro statsd metric (spec §9.3): wall-clock seconds from batch creation to
      # full success. `created_at` shares the CLOCK_REALTIME epoch we record it
      # with. No-op without a dogstatsd client.
      #
      # Strictly best-effort: a raise here would abort `fire_success` ahead of
      # the enqueue for the sake of a metric. Swallow and log instead.
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
          conn.pipelined { |pipe| Batch.keys_for(bid).each { |key| pipe.call('EXPIRE', key, seconds) } }
        end
      end

      # True once `b-<bid>-<event>` exists, i.e. an enqueue pass for `event`
      # has completed. The read-side half of the enqueue-then-mark ordering in
      # `fire_complete`/`fire_success`.
      def dedup_marked?(bid, event)
        Wurk.redis { |conn| conn.call('EXISTS', "b-#{bid}-#{event}") }.to_i == 1
      end

      # Writes `b-<bid>-<event>`, the marker that `event`'s callbacks have been
      # enqueued. Returns true when this call created it, false when it was
      # already there.
      #
      # Two usages, deliberately different: `fire_death` calls it *before* its
      # enqueue and treats the return as a claim (at most once); `fire_complete`
      # and `fire_success` call it *after* theirs and ignore the return, gating
      # on `dedup_marked?` instead. SET NX keeps both safe under racing acks.
      def dedup_set(bid, event)
        Wurk.redis do |conn|
          ok = conn.call('SET', "b-#{bid}-#{event}", '1', 'NX', 'EX', Batch::CALLBACK_NOTIFY_TTL)
          ok == 'OK'
        end
      end

      # The HSET resurrects the hash when a callback fires for a batch whose keys
      # already expired, so the write is followed by an NX stamp — without it the
      # resurrected hash would have no clock at all. NX leaves a live batch's
      # expiry, and the shorter post-success `linger` window, untouched.
      def record_event(bid, field)
        now = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
        Wurk.redis do |conn|
          conn.pipelined do |pipe|
            pipe.call('HSET', "b-#{bid}", field, now.to_s, field.delete_suffix('_at'), '1')
            pipe.call('EXPIRE', "b-#{bid}", Batch::DEFAULT_EXPIRY_SECONDS, 'NX')
          end
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
      # so nothing there ever clears them. Re-evaluated whenever a child
      # drains (propagate_to_parent): drop the durable death mark and
      # `dead-batches` membership once the batch's own died set is empty AND
      # no child still carries a death mark. The `b-<bid>-death` notify dedup
      # key is deliberately left intact, so a later re-death re-marks the batch
      # (fire_death restores the flag before its own dedup guard) without ever
      # re-enqueuing `:death`.
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
      # not keep the remaining callbacks for this event from being attempted.
      # Each failure reaches the error handlers; once all were attempted, any
      # failure raises so the caller does not write the event's marker.
      def enqueue_callbacks(bid, event)
        failed = callback_items(bid, event).count { |item| !push_callback(bid, event, item) }
        return if failed.zero?

        raise CallbackEnqueueError, "batch #{bid}: #{failed} #{event} callback(s) failed to enqueue"
      end

      def callback_items(bid, event)
        callbacks, queue, parent_bid = callback_specs_for(bid)
        parent_bid = nil if event == 'death'
        callbacks.filter_map do |(cb_event, target, options)|
          next unless cb_event == event

          item = callback_item(bid, target, event, options, queue)
          item['bid'] = parent_bid if parent_bid
          item
        end
      end

      # True when the callback job was enqueued.
      def push_callback(bid, event, item)
        Batch.with_thread_batch(nil, nil) { Wurk::Client.push(item) }
        true
      rescue StandardError => e
        Wurk.configuration.handle_exception(
          e, { context: "batch #{bid}: #{event} callback #{item['args'][1].inspect} enqueue failed", bid: bid }
        )
        false
      end

      def callback_specs_for(bid)
        callbacks_json, queue, parent_bid = Wurk.redis do |conn|
          conn.call('HMGET', "b-#{bid}", 'callbacks', 'callback_queue', 'parent_bid')
        end
        queue = 'default' if queue.nil? || queue.empty?
        parent_bid = nil if parent_bid.nil? || parent_bid.empty?
        [parse_callbacks(callbacks_json), queue, parent_bid]
      end

      def parse_callbacks(raw)
        return [] if raw.nil? || raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        []
      end

      # Pushed (by push_callback) with the batch thread-locals cleared: a
      # fire can run on a thread that is inside some other batch's `#jobs`
      # block (a hold released at the end of a nested block), and the client
      # middleware would otherwise stamp that batch's bid over the parent bid
      # — or the buffer would swallow the push until that block exits.
      def callback_item(bid, target, event, options, queue)
        {
          'class' => 'Wurk::Batch::CallbackJob',
          'args' => [bid, target, event, options],
          'queue' => queue,
          'retry' => true
        }
      end

      # When a child batch drains (by success or death), drop it from the
      # parent's pending children and re-evaluate the parent with the state
      # BATCH_KID_DONE read atomically alongside the SREM. A re-run of the
      # child (a reclaimed job, a re-drive) removes nothing but still reports
      # the parent's state, so a parent fire lost to a crash is re-driven too.
      #
      # A recovered child may have lifted the last death from the parent's
      # subtree — clear the parent's cascaded mark first, so the parent's
      # `:success` can fire whenever it next drains (here, or when this
      # child's callback jobs ack into it). Harmless on the death path: the
      # dying child still carries its mark, so any_child_dead? keeps the
      # parent dead.
      def propagate_to_parent(bid)
        parent_bid = parent_bid_for(bid)
        return if parent_bid.nil? || parent_bid.empty?

        clear_death_on_recovery(parent_bid)
        pending, live, kids = Wurk.redis do |conn|
          Wurk::Lua::Loader.eval_cached(
            conn, :batch_kid_done,
            keys: ["b-#{parent_bid}", "b-#{parent_bid}-jids", "b-#{parent_bid}-pkids"], argv: [bid]
          )
        end
        maybe_fire(parent_bid, pending: pending.to_i, live: live.to_i, kids: kids.to_i)
      end

      def parent_bid_for(bid)
        Wurk.redis { |conn| conn.call('HGET', "b-#{bid}", 'parent_bid') }
      end
    end
  end
end
