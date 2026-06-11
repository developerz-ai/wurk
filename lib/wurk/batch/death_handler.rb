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
    # Spec: docs/target/sidekiq-pro.md §2.4 (`:death`).
    class DeathHandler
      def self.call(job, _exception)
        bid = job['bid']
        return unless bid

        result = Wurk.redis do |conn|
          Wurk::Lua::Loader.eval_cached(
            conn,
            :batch_ack_complete,
            keys: ["b-#{bid}", "b-#{bid}-jids", "b-#{bid}-died", "b-#{bid}-failed"],
            argv: [job['jid']]
          )
        end
        live, _died, first_death = Array(result).map(&:to_i)

        Wurk::Batch::Callbacks.fire_death(bid) if first_death == 1
        return unless live.zero?

        # Through the gated maybe_fire, not a direct fire_complete: this batch
        # may still have running child batches, and spec §2.4 ordering says
        # its `:complete` must wait for theirs (#209). `:success` stays
        # suppressed regardless — the death above set the durable death flag.
        Wurk::Batch::Callbacks.maybe_fire(bid, pending: Wurk::Batch::Callbacks.pending_for(bid), live: 0)
      end
    end
  end
end

Wurk.configuration.death_handlers << Wurk::Batch::DeathHandler
