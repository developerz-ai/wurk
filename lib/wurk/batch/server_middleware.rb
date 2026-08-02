# frozen_string_literal: true

require 'json'
require_relative '../middleware'
require_relative '../lua'
require_relative '../job'
require_relative '../job_retry'

module Wurk
  class Batch
    # Server middleware. Runs around `perform` for any job carrying a `bid`.
    # On success → BATCH_ACK_SUCCESS → if pending hit zero and no deaths,
    # enqueue `:success` callback jobs; if live jids hit zero, enqueue
    # `:complete` callback jobs.
    #
    # On a job raising (and thus heading to retry), records a transient
    # failure → BATCH_ACK_FAILED → the jid joins `b-<bid>-failed` and
    # `failures` reflects the count of currently-failing jobs. A later
    # successful retry clears it; a terminal death moves it to `b-<bid>-died`.
    # Clean handled exits (JobRetry::Skip — from the interrupt handler or a
    # Limiter::Rescheduled re-enqueue — and cooperative IterableJob
    # interruption) are re-raised as neither success nor failure.
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

        run_and_ack(bid, job['jid']) { yield }
      end

      private

      # A handled/skip exit — including a Limiter::Rescheduled, where the
      # limiter already re-enqueued the job (Rescheduled < JobRetry::Skip <
      # Handled) — or a cooperative interruption is *neither* success nor
      # failure: re-raise it untouched, acking neither. Any other exception
      # means the job failed and will retry (or eventually die): record it
      # before re-raising.
      def run_and_ack(bid, jid)
        yield
        ack_success(bid, jid)
      rescue Wurk::JobRetry::Handled, Wurk::Job::Interrupted
        raise
      rescue StandardError
        ack_failed(bid, jid)
        raise
      end

      def invalidated?(bid)
        redis_pool.with { |conn| conn.call('HGET', "b-#{bid}", 'invalidated') } == '1'
      end

      def ack_success(bid, jid)
        result = redis_pool.with do |conn|
          Wurk::Lua::Loader.eval_cached(
            conn,
            :batch_ack_success,
            keys: ["b-#{bid}", "b-#{bid}-jids", "b-#{bid}-failed"],
            argv: [jid]
          )
        end
        pending, live = Array(result).map(&:to_i)
        return if pending.negative?

        Wurk::Batch::Callbacks.maybe_fire(bid, pending: pending, live: live)
      end

      def ack_failed(bid, jid)
        redis_pool.with do |conn|
          Wurk::Lua::Loader.eval_cached(
            conn,
            :batch_ack_failed,
            keys: ["b-#{bid}", "b-#{bid}-failed"],
            argv: [jid, Batch::DEFAULT_EXPIRY_SECONDS]
          )
        end
      end
    end
  end
end

require_relative 'callbacks'

Wurk.configuration.server_middleware.add(Wurk::Batch::ServerMiddleware)
