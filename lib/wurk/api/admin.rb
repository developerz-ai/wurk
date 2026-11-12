# frozen_string_literal: true

require_relative 'idempotency'
require_relative 'jobs'
require_relative 'page'
require_relative 'problem'
require_relative 'response'
require_relative 'validation'

module Wurk
  module API
    # The operator actions the dashboard already offers, for a client that has
    # no screen: put one retrying or dead job back on its queue, empty a queue.
    #
    # Each goes through the object the dashboard's action calls —
    # SortedEntry#retry, Queue#clear — so the two surfaces cannot disagree about
    # what "retry" does to `retry_count` or what "clear" removes.
    #
    # Neither is safe to send twice blind. A second retry after a lost reply
    # finds nothing and reads as a 404 the job did not earn, and a second clear
    # empties whatever was enqueued in between. So every route here takes
    # `Idempotency-Key` exactly as the produce plane does.
    module Admin
      module_function

      TABLE = [
        [:post, '/retries/:jid/retry', :admin, :retry_retrying],
        [:post, '/dead/:jid/retry', :admin, :retry_dead],
        [:post, '/queues/:name/clear', :admin, :clear]
      ].freeze

      def draw(router)
        TABLE.each do |verb, pattern, scope, handler|
          router.public_send(verb, pattern, scope: scope) do |request|
            claimed(request) { public_send(handler, request) }
          end
        end
      end

      def retry_retrying(request) = retry_entry(request, ::Wurk::RetrySet.new)
      def retry_dead(request) = retry_entry(request, ::Wurk::DeadSet.new)

      # A job the poller promoted, or another client retried, between the
      # lookup and the removal is not retried twice: SortedEntry#retry answers
      # nil when its ZREM finds nothing, and that is the same 404 a jid that
      # was never there gets.
      def retry_entry(request, set)
        jid = Validation.jid!(request.path_params[:jid].to_s)
        score = Validation.score!(Page.query!(request))
        entry = Jobs.find_entry(set, jid, score)
        return job_not_found(request, set, jid) unless entry&.retry

        Response.json(200, jid: jid, set: set.name, queue: entry.queue)
      end

      def clear(request)
        queue = ::Wurk::Queue.new(Validation.queue_name!(request.path_params[:name]))
        queue.clear
        Response.json(200, name: queue.name, cleared: true)
      end

      # The body cap and the shape of the key are checked before the claim, the
      # rest inside it, in the order Jobs#produce uses and for its reason: a
      # refusal releases the key, a success is what a resend replays.
      def claimed(request, &action)
        config = request.config
        raw = Validation.body!(request, config.api_max_body_bytes)
        Idempotency.around(request, raw, config) { Jobs.rejectable(request, &action) }
      rescue Validation::Invalid => e
        Problem.from(e, instance: request.path)
      end

      def job_not_found(request, set, jid)
        Problem.render(
          Problem::JOB_NOT_FOUND,
          status: 404,
          detail: "No job in #{set.name} has jid #{jid}.",
          instance: request.path,
          jid: jid
        )
      end
    end
  end
end
