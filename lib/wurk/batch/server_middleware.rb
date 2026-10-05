# frozen_string_literal: true

require_relative '../middleware'
require_relative '../lua'
require_relative '../job'
require_relative '../job_retry'
require_relative 'callbacks'

module Wurk
  class Batch
    # Server middleware. Runs around `perform` for any job carrying a `bid`.
    # On success → BATCH_ACK_SUCCESS → when that drains the batch, fire its
    # callbacks (Callbacks.maybe_fire).
    #
    # On a job raising (and thus heading to retry), records a transient
    # failure → BATCH_ACK_FAILED → the jid joins `b-<bid>-failed` and
    # `failures` reflects the count of currently-failing jobs. A later
    # successful retry clears it; a terminal death moves it to `b-<bid>-died`.
    # Clean handled exits (JobRetry::Skip — from the interrupt handler or a
    # Limiter::Rescheduled re-enqueue — and cooperative IterableJob
    # interruption) are re-raised as neither success nor failure.
    #
    # The success ack runs outside the job's rescue: once `perform` returned,
    # nothing the batch bookkeeping raises may be mistaken for the job failing,
    # or a job that already did its work is retried and runs twice. The ack
    # itself is retried in-process and only raises (sending the job to retry,
    # at-least-once) when Redis stays unreachable — a jid left in the live set
    # would hold the batch open forever. The fire after it never raises: it is
    # re-driven in-process and then reported to the error handlers.
    #
    # Invalidated batches short-circuit: the job is skipped without
    # raising — counts as a "success" for batch purposes per spec §12.
    # A callback job is never skipped: it rides in its *parent* batch (see
    # Callbacks), and a cancelled parent must not swallow a child's callback.
    #
    # Death handling lives in Wurk::Batch::DeathHandler (registered as a
    # config death_handler) because death is signalled from the retry layer,
    # not from this middleware's rescue path.
    class ServerMiddleware
      include Wurk::Middleware::ServerMiddleware

      CALLBACK_JOB = 'Wurk::Batch::CallbackJob'

      def call(_worker, job, _queue, &)
        bid = job['bid']
        return yield unless bid

        jid = job['jid']
        run(bid, jid, &) if job['class'] == CALLBACK_JOB || !invalidated?(bid)
        ack_success(bid, jid)
      end

      private

      # A handled/skip exit — including a Limiter::Rescheduled, where the
      # limiter already re-enqueued the job (Rescheduled < JobRetry::Skip <
      # Handled) — or a cooperative interruption is *neither* success nor
      # failure: re-raise it untouched, acking neither. Any other exception
      # means the job failed and will retry (or eventually die): record it
      # before re-raising.
      def run(bid, jid)
        yield
      rescue Wurk::JobRetry::Handled, Wurk::Job::Interrupted
        raise
      rescue StandardError
        ack_failed(bid, jid)
        raise
      end

      def invalidated?(bid)
        redis_pool.with { |conn| conn.call('HGET', "b-#{bid}", 'invalidated') } == '1'
      end

      # A jid that was no longer live (`removed == 0`) is a re-run — most
      # often a job reclaimed after a SIGKILL that landed between this ack and
      # the fire. It still goes through the gate with the batch's current
      # state: if the batch is drained, the dead run's fire may never have
      # happened, and the callback markers absorb it if it did.
      def ack_success(bid, jid)
        _removed, pending, live, kids = Callbacks.retrying do
          redis_pool.with { |conn| Batch.ack_success(conn, bid, jid) }
        end
        fire(bid, pending, live, kids)
      end

      def fire(bid, pending, live, kids)
        Callbacks.retrying { Callbacks.maybe_fire(bid, pending: pending, live: live, kids: kids) }
      rescue StandardError => e
        error_config.handle_exception(e, { context: "batch #{bid}: firing callbacks after ack", bid: bid })
      end

      # `config` is a Configuration or a Capsule; only the former reports.
      def error_config
        config.respond_to?(:handle_exception) ? config : config.config
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

Wurk.configuration.server_middleware.add(Wurk::Batch::ServerMiddleware)
