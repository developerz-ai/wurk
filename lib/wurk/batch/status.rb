# frozen_string_literal: true

require 'json'
require_relative '../lua'
require_relative 'callbacks'

module Wurk
  class Batch
    # Snapshot of a batch's state — read-only view backed by HGETALL of
    # `b-<bid>` plus the supporting JIDs/failed/died sets. Mirrors the
    # Sidekiq::Batch::Status surface from docs/target/sidekiq-pro.md §2.5.
    #
    # `#data` returns the JSON-friendly hash served by the polling endpoint.
    # `#join` blocks the current thread until `complete?` — test/util only.
    # `#delete` removes the batch and every reference to it.
    class Status
      JOIN_POLL_INTERVAL = 0.5

      attr_reader :bid

      def initialize(bid)
        raise ArgumentError, 'bid required' if bid.nil? || bid.to_s.empty?

        @bid = bid.to_s
        reload!
      end

      # False when no `b-<bid>` hash exists — a well-formed bid that was never
      # created (or has expired). Lets callers 404 instead of serving an
      # all-zero phantom batch.
      def exists? = !@data.empty?

      def total            = @data['total'].to_i
      def pending          = @data['pending'].to_i
      def failures         = @data['failures'].to_i
      def created_at       = numeric_or_nil(@data['created_at'])
      def complete_at      = numeric_or_nil(@data['complete_at'])
      def success_at       = numeric_or_nil(@data['success_at'])
      def death_at         = numeric_or_nil(@data['death_at'])
      def description      = @data['description']
      def parent_bid       = @data['parent_bid']
      def callback_queue   = @data['callback_queue']
      def invalidated?     = @data['invalidated'] == '1'

      # `:complete` fires when the live jids set is empty (every job has
      # either succeeded or died). Hash field is set by the server callback;
      # falling back to a recompute keeps Status accurate even if the
      # callback dispatch is in flight.
      def complete?
        return true if @data['complete'] == '1'

        complete_with?(live_jids_count)
      end

      def failed_jids
        Wurk.redis { |conn| conn.call('SMEMBERS', "b-#{@bid}-failed") }
      end

      # Deprecated pre-Pro8 surface (spec §2.5): an array of per-failure error
      # detail. The Pro8 data model (§2.8) drops the `b-<bid>-failinfo` hash in
      # favour of the `failed_jids` set, which Wurk tracks — so the per-jid
      # error payload is intentionally not persisted and this returns []. Kept
      # so drop-in callers referencing `#failure_info` don't NameError.
      def failure_info
        []
      end

      def dead_jids
        Wurk.redis { |conn| conn.call('SMEMBERS', "b-#{@bid}-died") }
      end

      def child_count
        Wurk.redis { |conn| conn.call('SCARD', "b-#{@bid}-kids") }.to_i
      end

      def tags
        raw = @data['tags']
        return [] if raw.nil? || raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        []
      end

      # JSON-serializable snapshot used by the polling middleware / web UI.
      # Field names are wire-compat with Sidekiq Pro's BatchStatus. The four
      # set reads it needs ride one pipeline.
      def data
        failed, dead, kids, live = set_snapshot
        {
          'bid' => @bid,
          'total' => total,
          'pending' => pending,
          'failures' => failures,
          'created_at' => created_at,
          'complete_at' => complete_at,
          'success_at' => success_at,
          'death_at' => death_at,
          'complete' => complete_with?(live.to_i),
          'invalidated' => invalidated?,
          'description' => description,
          'parent_bid' => parent_bid,
          'tags' => tags,
          'failed_jids' => failed,
          'dead_jids' => dead,
          'child_count' => kids.to_i
        }
      end

      # Blocks the current thread until `complete?` is true. Test/util only —
      # polling Redis from a worker thread would defeat the whole point of
      # asynchronous batches.
      def join
        loop do
          reload!
          break if complete?

          sleep JOIN_POLL_INTERVAL
        end
      end

      # Nukes every key for this batch, its index entries and tag indexes,
      # and its membership in the parent's `-kids`/`-pkids` — one atomic
      # script (BATCH_DELETE). Dangerous if jobs are still in flight: they'll
      # succeed/fail without a batch to ack against and this batch's callbacks
      # won't fire. The *parent* is not left waiting on a child that no longer
      # exists: when this was the last thing it waited on, its callbacks fire
      # here.
      def delete
        reload!
        parent = parent_bid.to_s
        own    = Batch.keys_for(@bid)
        pending, live, kids = Wurk.redis do |conn|
          Wurk::Lua::Loader.eval_cached(conn, :batch_delete, keys: delete_keys(own, parent),
                                                             argv: [@bid, own.size, parent.empty? ? '0' : '1'])
        end.map(&:to_i)
        Callbacks.maybe_fire(parent, pending: pending, live: live, kids: kids) unless parent.empty?
        nil
      end

      def reload!
        raw = Wurk.redis { |conn| conn.call('HGETALL', "b-#{@bid}") }
        @data = raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
        self
      end

      private

      # [failed jids, dead jids, child count, live count] in one round trip.
      def set_snapshot
        Wurk.redis do |conn|
          conn.pipelined do |pipe|
            pipe.call('SMEMBERS', "b-#{@bid}-failed")
            pipe.call('SMEMBERS', "b-#{@bid}-died")
            pipe.call('SCARD', "b-#{@bid}-kids")
            pipe.call('SCARD', "b-#{@bid}-jids")
          end
        end
      end

      # KEYS layout BATCH_DELETE expects.
      def delete_keys(own, parent)
        keys = [*own, 'batches', 'dead-batches']
        keys.push("b-#{parent}", "b-#{parent}-jids", "b-#{parent}-pkids", "b-#{parent}-kids") unless parent.empty?
        keys.concat(tags.map { |t| "tags:#{t}" })
      end

      def complete_with?(live)
        @data['complete'] == '1' || (total.positive? && live.zero?)
      end

      def live_jids_count
        Wurk.redis { |conn| conn.call('SCARD', "b-#{@bid}-jids") }.to_i
      end

      def numeric_or_nil(val)
        return nil if val.nil? || val.to_s.empty?

        val.to_f
      end
    end
  end
end
