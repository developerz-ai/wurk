# frozen_string_literal: true

require_relative '../middleware'
require_relative '../job'
require_relative '../job_retry'
require_relative '../status'

module Wurk
  module Middleware
    # Drives the `status:<jid>` lifecycle for a worker class that opted in with
    # `sidekiq_options track: true`. Every other class — the default — costs one
    # Hash lookup and a `yield`.
    #
    #   running ──┬─▶ complete     perform returned; its value is captured
    #             ├─▶ interrupted  cooperative stop (IterableJob)
    #             └─▶ failed ──┬─▶ retrying   a retry was scheduled
    #                          └─▶ dead       retries exhausted / discarded
    #
    # (`enqueued` is written at push time by the client, not here.)
    #
    # `failed` is written the moment the attempt raises, because that much is
    # always true. Whether the job then retries or dies is decided one frame
    # further out, in {Wurk::JobRetry} — which is why `retrying` is written from
    # there via {.retrying} and `dead` from {DeathHandler}, instead of being
    # guessed at here. Guessing would mean a second implementation of retry
    # policy (`retry_for`, `sidekiq_retry_in` returning `:discard`/`:kill`,
    # `dead: false`, poison-pill kills), and the two would drift.
    #
    # Registered last of the built-ins, inside `Metrics::History`: the stored
    # result is `perform`'s own return value, so none of them may wrap or
    # replace it before this one sees it.
    class Status
      include Wurk::Middleware::ServerMiddleware

      # Hard cap on a stored result, in bytes. A job that returns an
      # ActiveRecord relation must cost Redis 8 KB, not a table dump — past the
      # cap the head is kept and `result_truncated` says the rest was dropped.
      MAX_RESULT_BYTES = 8 * 1024

      # Same reasoning for the error text: a parser whose message quotes the
      # whole offending document would otherwise store the document.
      MAX_ERROR_BYTES = 1024

      # The lifecycle is inline rather than split across a helper so the
      # untracked path is a Hash lookup and a bare `yield`: taking the block as
      # `&block`, or handing it to another method, allocates a Proc for every
      # job in the process, tracked or not.
      #
      # Rescue taxonomy mirrors Batch::ServerMiddleware — a handled skip and a
      # cooperative interruption are not failures. Caveat inherited from the
      # chain position it shares with Metrics::History: a `Limiter::OverLimit`
      # raised inside the job body unwinds through here *before* Limiter (outer)
      # converts it into a reschedule, so a rate-limited job books `failed` for
      # an attempt it never ran. Pinned for History in
      # test/unit/metrics_history_test.rb; fixing it needs the chain-order
      # decision that test defers, and Status must not answer it differently
      # from its two siblings in the meantime.
      def call(worker, job, queue)
        jid = job['jid']
        return yield unless ::Wurk::Status.tracked?(job) && jid && !jid.empty?

        progress = attach_progress(worker, jid)
        started(jid, job, queue)
        begin
          result = yield
          complete(jid, job, progress, result)
          result
        rescue ::Wurk::Job::Interrupted
          interrupted(jid, progress)
          raise
        rescue ::Wurk::JobRetry::Handled
          # Neither success nor failure: the job has been put back on a queue
          # and will run again. Leave the row `running` and keep the progress it
          # reported, so the next attempt continues the same story.
          safely { progress.flush }
          raise
        rescue StandardError => e
          failed(jid, progress, e)
          raise
        end
      end

      # Every way a job stops coming back funnels through the death handlers:
      # retries exhausted, `dead: false`, a `:discard` from `sidekiq_retry_in`,
      # a poison-pill kill. Same registration shape as `Batch::DeathHandler`.
      module DeathHandler
        def self.call(job, _exception) = Status.dead(job)
      end

      class << self
        # Called by {Wurk::JobRetry#schedule_retry} once the retry is on the
        # ZSET — the first moment anyone knows this failure is a retry rather
        # than a death.
        def retrying(job) = record_outcome(job, 'retrying')

        def dead(job) = record_outcome(job, 'dead')

        # byteslice, not slice: the cap is a byte budget, and 8192 *characters*
        # is 32 KB of UTF-8 in the worst case. Cutting on a byte boundary can
        # split a multi-byte character, so the dangling tail is scrubbed away.
        #
        # @api private
        def truncate(text, limit)
          return text if text.bytesize <= limit

          text.byteslice(0, limit).scrub('')
        end

        # @api private
        def report(error, context)
          Wurk.configuration.handle_exception(error, context: "Wurk::Middleware::Status: #{context}")
        end

        private

        # Runs with no middleware instance and therefore no capsule, so the
        # write goes through the process-wide pool — same as Batch::DeathHandler.
        # JobRetry has already stamped the error fields and bumped
        # `retry_count` on this hash by the time either caller gets here, and
        # `retry_count` is 0-based, so it names the attempt that just failed.
        def record_outcome(job, state)
          return unless ::Wurk::Status.tracked?(job)

          jid = job['jid']
          return if jid.nil? || jid.to_s.empty?

          message = job['error_message']
          ::Wurk::Status.write(jid, state: state, attempt: job['retry_count'].to_i + 1,
                                    error_class: job['error_class'],
                                    error_message: message && truncate(message.to_s, MAX_ERROR_BYTES))
        rescue StandardError => e
          report(e, "writing #{state}")
        end
      end

      private

      # The handle a tracked job reaches through `status.at(...)`. Assigned only
      # when the worker can take it — the chain is also invoked with a nil or
      # Struct-shaped worker (ActiveJob wrappers, direct chain tests), and those
      # still get a lifecycle, just no in-job progress.
      def attach_progress(worker, jid)
        handle = ::Wurk::Status::Progress.new(jid, pool: redis_pool)
        worker.status = handle if worker.respond_to?(:status=)
        handle
      end

      def started(jid, job, queue)
        safely do
          ::Wurk::Status.write(jid, pool: redis_pool, state: 'running', class: job['class'],
                                    queue: job['queue'] || queue, enqueued_at: enqueued_at(job),
                                    started_at: now, attempt: attempt_for(job))
        end
      end

      # The three terminal transitions. Each builds its fields *inside*
      # `safely`, so neither a Redis blip nor a return value that refuses to
      # serialize can replace the exception the caller is about to re-raise.
      #
      # `status_retention` bends the row's lifetime, and only here: a job that
      # succeeded is the one the census gap is about — Sidekiq loses it the
      # instant it finishes — while a failed or dead job is still findable in
      # the retry and dead sets. `0` reproduces that loss on purpose, so a host
      # that wants tracking only for jobs in flight keeps today's key space.
      def complete(jid, job, progress, result)
        keep = ::Wurk::Status.retention
        return safely { ::Wurk::Status.delete(jid, pool: redis_pool) } if keep&.zero?

        safely { finish(jid, progress, ttl: keep, state: 'complete', **encode_result(job, result)) }
      end

      def interrupted(jid, progress)
        safely { finish(jid, progress, state: 'interrupted') }
      end

      def failed(jid, progress, error)
        safely { finish(jid, progress, state: 'failed', **encode_error(error)) }
      end

      # One write per terminal transition: `progress.drain` folds the job's last
      # buffered position into it rather than paying a round trip of its own.
      def finish(jid, progress, **fields)
        ::Wurk::Status.write(jid, pool: redis_pool, finished_at: now, **progress.drain, **fields)
      end

      # JSON only (CLAUDE.md). nil is the overwhelmingly common return value and
      # answers nothing a missing field doesn't, so it is not stored at all.
      #
      # A value that only serializes via a `to_json` of its own (an AR relation,
      # a model) is serialized, then capped — opting into tracking is opting
      # into that cost. Anything that raises on the way is dropped: a result is
      # a record of the job, never a reason to fail it.
      def encode_result(job, value)
        return {} if value.nil?
        return { result_withheld: '1' } if withhold_result?(job)

        json = ::Wurk.dump_json(value)
        return { result: json } if json.bytesize <= MAX_RESULT_BYTES

        { result: self.class.truncate(json, MAX_RESULT_BYTES), result_truncated: '1' }
      rescue StandardError => e
        self.class.report(e, 'serializing job result')
        {}
      end

      # `encrypt: true` declares the last argument a secret, and a job handed a
      # secret usually returns something derived from it — so storing `perform`'s
      # value verbatim would put back into a plaintext HASH exactly what
      # enveloping the args kept out of Redis. Encrypting the row instead was the
      # alternative and was rejected: the crypto contract is scoped to the last
      # positional argument (docs/target/sidekiq-ent.md §4), and every reader of
      # a status row — dashboard, HTTP API, a chain piping the result onward —
      # would then need the key. `result_withheld` marks the drop as policy so it
      # doesn't read as "returned nothing".
      #
      # Only the result is withheld, because only the result is new: the whole
      # combination is refused nowhere (unlike Wurk::Unique, whose digest
      # encryption genuinely breaks — see Unique::ClientMiddleware
      # #reject_encrypted!), and `error_class`/`error_message` are already stored
      # verbatim on the retry and dead records by Sidekiq itself while a
      # `status.at(n, total, msg)` message is text the job chose to publish.
      #
      # The payload's own declaration decides this, not `Encryption.enabled?`, so
      # what a job leaves behind never depends on whether crypto happened to be
      # configured in the process that ran it — including the case the docs call
      # out as a silent no-op, where `encrypt: true` is set but `enable` was
      # never called and the args went to Redis in cleartext anyway.
      def withhold_result?(job) = job['encrypt'] ? true : false

      def encode_error(exception)
        { error_class: exception.class.name,
          error_message: self.class.truncate(exception.message.to_s, MAX_ERROR_BYTES) }
      end

      # `created_at` is epoch millis on the wire (JobUtil#now_in_millis) and
      # `enqueued_at` is re-stamped in millis every time the job hits a queue;
      # the status row keeps epoch-second Floats so all four timestamps on it
      # compare directly. Written on every attempt rather than trusted from the
      # client's `enqueued` row, so a job pushed by something that never wrote
      # one — stock Sidekiq, a raw LPUSH, a re-push from the UI — still ends up
      # with a complete set of timings.
      def enqueued_at(job)
        millis = job['enqueued_at'] || job['created_at']
        millis && (millis.to_f / 1000.0)
      end

      # `retry_count` is stamped 0 on the *first* failure (JobRetry
      # #bump_retry_count), so the run that follows it is execution 2.
      def attempt_for(job)
        count = job['retry_count']
        count ? count.to_i + 2 : 1
      end

      def now = ::Process.clock_gettime(::Process::CLOCK_REALTIME)

      # A status row is a record of the job, not part of it: a Redis blip while
      # writing one must not turn a job that succeeded into a retry.
      def safely
        yield
      rescue StandardError => e
        self.class.report(e, 'writing job status')
      end
    end
  end
end

Wurk.configuration.server_middleware.add(Wurk::Middleware::Status)
Wurk.configuration.death_handlers << Wurk::Middleware::Status::DeathHandler
