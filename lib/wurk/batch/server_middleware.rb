# frozen_string_literal: true

require 'json'
require_relative '../middleware'
require_relative '../lua'

module Wurk
  class Batch
    # Server middleware. Runs around `perform` for any job carrying a `bid`.
    # On success → BATCH_ACK_SUCCESS → if pending hit zero and no deaths,
    # enqueue `:success` callback jobs; if live jids hit zero, enqueue
    # `:complete` callback jobs.
    #
    # Invalidated batches short-circuit: the job is skipped without
    # raising — counts as a "success" for batch purposes per spec §12.
    #
    # Death handling lives in Wurk::Batch::DeathHandler (registered as a
    # config death_handler) because death is signalled from the retry layer,
    # not from this middleware's rescue path.
    class ServerMiddleware
      include Wurk::Middleware::ServerMiddleware

      def call(_worker, job, _queue)
        bid = job['bid']
        return yield unless bid

        if invalidated?(bid)
          ack_success(bid, job['jid'])
          return
        end

        yield
        ack_success(bid, job['jid'])
      end

      private

      def invalidated?(bid)
        redis_pool.with { |conn| conn.call('HGET', "b-#{bid}", 'invalidated') } == '1'
      end

      def ack_success(bid, jid)
        result = redis_pool.with do |conn|
          Wurk::Lua::Loader.eval_cached(
            conn,
            :batch_ack_success,
            keys: ["b-#{bid}", "b-#{bid}-jids"],
            argv: [jid]
          )
        end
        pending, live = Array(result).map(&:to_i)
        return if pending.negative?

        Wurk::Batch::Callbacks.maybe_fire(bid, pending: pending, live: live)
      end
    end
  end
end

require_relative 'callbacks'

Wurk.configuration.server_middleware.add(Wurk::Batch::ServerMiddleware)
