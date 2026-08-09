# frozen_string_literal: true

require_relative 'idempotency'
require_relative 'problem'
require_relative 'response'
require_relative 'validation'

module Wurk
  module API
    # The produce plane: enqueue one job, enqueue many, take a not-yet-run job
    # back out.
    #
    # The request body *is* the Sidekiq job hash — `{"class", "args", "queue",
    # "at", "retry"}` — and every write below hands it to {Wurk::Client}, the
    # same object `perform_async` reaches. Nothing here builds, renames, or
    # re-keys a payload. That is the drop-in guarantee written as code: an
    # HTTP-enqueued job is the same bytes in the same Redis structures as a
    # Ruby-enqueued one, so stock Sidekiq runs it. A payload assembled here
    # would pass its own tests forever and be wrong the first time Client
    # changed.
    #
    # Client is instantiated per request rather than memoized, and without a
    # config, for the same reason: it must resolve the process's own middleware
    # chain and pool at call time — exactly what a Ruby producer in this process
    # gets — and the canonical inspectors this plane shares Redis with
    # (ScheduledSet, RetrySet) read `Wurk.redis` unconditionally.
    #
    # What a stranger may send is {Validation}'s job, and whether a retry of it
    # counts twice is {Idempotency}'s. This module owns only the three routes
    # and the order those two run in.
    module Jobs
      module_function

      def draw(router)
        router.post('/jobs', scope: :enqueue) { |request| create(request) }
        router.post('/jobs/bulk', scope: :enqueue) { |request| create_bulk(request) }
        # :admin, not :enqueue. A jid is not bound to the token that produced
        # it, so an enqueue-scoped producer holding this route could walk the
        # retry set one jid at a time. Widening a scope later is additive to
        # every client; narrowing one breaks them.
        router.delete('/jobs/:jid', scope: :admin) { |request| destroy(request) }
      end

      # 201 with the jid, or 200 with a null one when client middleware halted
      # the push — a `collapse:`/`unique_for:` drop is the producer's own policy
      # doing its job, not a failure to report as one.
      def create(request)
        produce(request) do |payload, config|
          Validation.job!(payload, principal: request.principal, config: config)
          jid = ::Wurk::Client.new.push(payload)
          Response.json(jid ? 201 : 200, jid: jid)
        end
      end

      # The `push_bulk` shape verbatim: one `class`, an array of arg arrays, and
      # optionally `at`/`spread_interval`/`batch_size`. Nil entries in `jids`
      # mark the jobs middleware halted, positionally.
      def create_bulk(request)
        produce(request) do |payload, config|
          Validation.bulk!(payload, principal: request.principal, config: config)
          jids = ::Wurk::Client.new.push_bulk(payload)
          Response.json(jids.any? { |jid| !jid.nil? } ? 201 : 200, jids: jids)
        end
      end

      # The shape both produce routes share.
      #
      # The body cap runs first, because it is the only check that can be made
      # without holding the request. The `Idempotency-Key` claim wraps
      # everything after it — parsing, validation and the push alike. That
      # looks like it burns a client's key on a malformed body and does not:
      # the claim releases on any answer that isn't a success, so the
      # correction can be sent under the same key. What it buys is that the key
      # is claimed *before* the push, the only ordering in which two concurrent
      # retries of a dropped connection can't both enqueue.
      def produce(request)
        config = request.config
        raw = Validation.body!(request, config.api_max_body_bytes)
        Idempotency.around(request, raw, config) { rejectable(request) { yield(Validation.object!(raw), config) } }
      rescue Validation::Invalid => e
        # Only the two checks above the claim reach here — the body cap, and
        # the shape of the Idempotency-Key itself. Everything below is answered
        # inside the claim, where the status it decides on is visible.
        problem(request, e)
      end

      # Renders a refusal *inside* the claim, so what the claim weighs is a
      # response with a status on it rather than an exception it could only
      # release on. Client owns what a valid job hash is past the boundary; the
      # route surfaces its verdict instead of duplicating it.
      def rejectable(request)
        yield
      rescue Validation::Invalid => e
        problem(request, e)
      rescue ::ArgumentError => e
        invalid_request(request, e.message)
      end

      # Removes a job that has not run yet from `schedule` or `retry`. Not a
      # cancel: a job already handed to a processor keeps running, and one that
      # has already died stays in `dead`, where deleting it is an operator
      # action against a different set.
      def destroy(request)
        jid = Validation.jid!(request.path_params[:jid].to_s)
        set = cancellable_sets.find { |candidate| remove(candidate, jid) }
        return job_not_found(request, jid) unless set

        Response.json(200, jid: jid, set: set.name)
      rescue Validation::Invalid => e
        problem(request, e)
      end

      # `schedule` first: a job merely waiting for its time is the one a
      # producer usually means to call off, and a jid in both sets at once
      # would mean something else is already broken.
      def cancellable_sets = [::Wurk::ScheduledSet.new, ::Wurk::RetrySet.new]

      # Find-then-delete through the canonical inspectors rather than a second
      # deletion path over the same ZSETs — the dashboard and every third-party
      # tool use these objects, and two ways to remove a member is a place for
      # them to disagree. A job promoted out of the set between the two steps
      # removes nothing and reads as "already gone", the honest answer to a
      # cancel that lost the race.
      def remove(set, jid)
        entry = set.find_job(jid)
        entry ? entry.delete : false
      end

      # Validation decided which problem this is; rendering it is all that is
      # left, so a new rejection never needs a new arm here.
      def problem(request, error)
        Problem.render(error.type, status: error.status, detail: error.message, instance: request.path, **error.extra)
      end

      def invalid_request(request, detail)
        Problem.render(Problem::INVALID_REQUEST, status: 400, detail: detail, instance: request.path)
      end

      def job_not_found(request, jid)
        Problem.render(
          Problem::JOB_NOT_FOUND,
          status: 404,
          detail: "No scheduled or retrying job has jid #{jid}.",
          instance: request.path,
          jid: jid
        )
      end
    end
  end
end
