# frozen_string_literal: true

require 'json'
require_relative 'problem'
require_relative 'response'

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
    module Jobs
      # Raised for a body this module rejects before Client ever sees it.
      # Client's own ArgumentError covers everything past that point.
      class Invalid < StandardError; end

      # A jid reaches Redis as a ZSCAN glob (JobSet#find_job wraps it in `*`),
      # so an unbounded or metacharacter-carrying jid off the network is a scan
      # this API runs on the client's behalf. Sidekiq's own jids are
      # `SecureRandom.hex(12)`; admit any URL-safe token of a sane length and
      # refuse the rest at the door.
      JID_FORMAT = /\A[A-Za-z0-9_-]{1,255}\z/

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
        jid = ::Wurk::Client.new.push(object_body(request))
        Response.json(jid ? 201 : 200, jid: jid)
      rescue Invalid, ::ArgumentError => e
        invalid_request(request, e.message)
      end

      # The `push_bulk` shape verbatim: one `class`, an array of arg arrays, and
      # optionally `at`/`spread_interval`/`batch_size`. Nil entries in `jids`
      # mark the jobs middleware halted, positionally.
      def create_bulk(request)
        jids = ::Wurk::Client.new.push_bulk(object_body(request))
        Response.json(jids.any? { |jid| !jid.nil? } ? 201 : 200, jids: jids)
      rescue Invalid, ::ArgumentError => e
        invalid_request(request, e.message)
      end

      # Removes a job that has not run yet from `schedule` or `retry`. Not a
      # cancel: a job already handed to a processor keeps running, and one that
      # has already died stays in `dead`, where deleting it is an operator
      # action against a different set.
      def destroy(request)
        jid = request.path_params[:jid].to_s
        return invalid_request(request, 'A jid is a URL-safe token of up to 255 characters.') unless valid_jid?(jid)

        set = cancellable_sets.find { |candidate| remove(candidate, jid) }
        return job_not_found(request, jid) unless set

        Response.json(200, jid: jid, set: set.name)
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

      def valid_jid?(jid) = JID_FORMAT.match?(jid)

      # The body is the job hash with no envelope around it. Client owns what a
      # valid one is; this only insists it is a JSON object at all, because
      # everything downstream indexes it by key.
      def object_body(request)
        parsed = ::JSON.parse(request.body&.read.to_s)
        raise Invalid, 'The request body must be a JSON object.' unless parsed.is_a?(::Hash)

        parsed
      rescue ::JSON::ParserError
        # Deliberately not the parser's own message: it quotes the unparsed
        # remainder of the document, so a large malformed body would come back
        # as a large error.
        raise Invalid, 'The request body is not valid JSON.'
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
