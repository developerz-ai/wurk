# frozen_string_literal: true

require_relative '../lua'
require_relative 'callbacks'

module Wurk
  class Batch
    # Registered as a config death_handler. Fires for every job that
    # exhausts retries or carries `dead: false` and discards. If the job
    # carries a `bid`, we BATCH_ACK_COMPLETE → record the death → fire
    # `:death` callback exactly once per batch (first death only).
    #
    # The retry layer runs this after the job is already in the morgue and
    # acked off its private list, and swallows whatever it raises — nothing
    # would ever deliver this death to the batch again. So the whole pass is
    # re-driven in-process (`Callbacks.retrying`): the ack script is
    # SREM/SADD-guarded and the fires are marker-guarded, so a replay is safe.
    # A replay can't trust `first_death` (the lost attempt may already have
    # moved the jid into the died set), so it falls back to the `:death`
    # claim marker to decide whether `:death` still has to fire.
    #
    # Spec: docs/target/sidekiq-pro.md §2.4 (`:death`).
    class DeathHandler
      def self.call(job, _exception)
        bid = job['bid']
        return unless bid

        Callbacks.retrying { |attempt| record(bid, job['jid'], replay: attempt.positive?) }
      end

      def self.record(bid, jid, replay:)
        live, _died, first_death, kids, pending = Wurk.redis do |conn|
          Wurk::Lua::Loader.eval_cached(
            conn,
            :batch_ack_complete,
            keys: ["b-#{bid}", "b-#{bid}-jids", "b-#{bid}-died", "b-#{bid}-failed", "b-#{bid}-pkids"],
            argv: [jid, Batch::DEFAULT_EXPIRY_SECONDS]
          )
        end.map(&:to_i)

        restamp_ttls(bid)

        Callbacks.fire_death(bid) if first_death == 1 || (replay && !Callbacks.dedup_marked?(bid, 'death'))

        # Through the gated maybe_fire, not a direct fire_complete: this batch
        # may still have running child batches, and spec §2.4 ordering says
        # its `:complete` must wait for theirs (#209). `:success` stays
        # suppressed regardless — the death above set the durable death flag.
        Callbacks.maybe_fire(bid, pending: pending, live: live, kids: kids)
      end

      # BATCH_ACK_COMPLETE stamps the two keys it can itself resurrect; this
      # sweeps the rest of the batch (`-jids`, `-failed`, `-kids`, `-pkids`,
      # callback markers). A death is the one moment we know the batch is
      # winding down, so it is worth a round trip to leave nothing without a
      # clock. EXPIRE NX touches only keys that have none, so a live batch's
      # clock and a post-success `linger` window both survive.
      def self.restamp_ttls(bid)
        Wurk.redis do |conn|
          conn.pipelined do |pipe|
            Batch.keys_for(bid).each { |key| pipe.call('EXPIRE', key, Batch::DEFAULT_EXPIRY_SECONDS, 'NX') }
          end
        end
      end
    end
  end
end

Wurk.configuration.death_handlers << Wurk::Batch::DeathHandler
