# frozen_string_literal: true

require_relative 'page'
require_relative 'problem'
require_relative 'response'
require_relative 'serializers'
require_relative 'validation'

module Wurk
  module API
    # The observe plane: how deep the queues are, what is waiting to retry,
    # what died, and the counters over the lot.
    #
    # Every route reads through a canonical inspector — {Wurk::Stats},
    # {Wurk::Queue}, {Wurk::RetrySet}, {Wurk::ScheduledSet}, {Wurk::DeadSet},
    # {Wurk::Batch::Status} — the same objects the dashboard reads. Not to save
    # code: a second reader over the same Redis keys is a second place for the
    # size-descending queue order, the latency math, the `paused` set and the
    # ActiveJob unwrapping to drift, and a dashboard and an API that disagree
    # about how deep a queue is are worse than either on its own.
    #
    # Pause and unpause are the only writes, and they go through
    # {Wurk::Queue#pause!} / {Wurk::Queue#unpause!}, which expire this
    # process's fetcher cache of the `paused` set. A bare SADD here would leave
    # the swarm fetching from a queue the API had just reported paused.
    module Queues
      module_function

      # Verb, pattern, the scope a caller must hold, handler. A table rather
      # than nine `router.get` calls because the scope column is the part that
      # has to be read at a glance: the two writes take :admin, not :read.
      # Pausing `default` stops the fleet from working without enqueueing or
      # deleting anything, so it belongs with the destructive routes rather
      # than with the listings it sits beside.
      TABLE = [
        [:get, '/stats', :read, :stats],
        [:get, '/queues', :read, :index],
        [:get, '/queues/:name', :read, :show],
        [:get, '/retries', :read, :retries],
        [:get, '/scheduled', :read, :scheduled],
        [:get, '/dead', :read, :dead],
        [:get, '/batches', :read, :batches],
        [:get, '/batches/:bid', :read, :batch],
        [:post, '/queues/:name/pause', :admin, :pause],
        [:post, '/queues/:name/unpause', :admin, :unpause]
      ].freeze

      # The refusal rendering wraps every handler here rather than sitting in
      # each one: they all validate something that came off the network, and a
      # rescue repeated per route is one a new route gets written without.
      def draw(router)
        TABLE.each do |verb, pattern, scope, handler|
          router.public_send(verb, pattern, scope: scope) do |request|
            public_send(handler, request)
          rescue Validation::Invalid => e
            Problem.from(e, instance: request.path)
          end
        end
      end

      def stats(_request)
        Response.json(200, Serializers.stats(::Wurk::Stats::Snapshot.new))
      end

      # A Stats snapshot rather than Queue.all: two pipelines instead of an
      # LLEN round trip per queue, and it comes back in the size-descending
      # order every other Wurk surface lists queues in.
      def index(_request)
        Response.json(200, queues: ::Wurk::Stats::Snapshot.new.queue_summaries.map { |q| Serializers.queue_summary(q) })
      end

      # No 404 for a name nothing was ever enqueued under. A queue is not an
      # entity in the Sidekiq schema — it is a LIST that exists only while it
      # has members — so "never used" and "drained" are the same state in
      # Redis, and `size: 0` is the honest reading of both. Pausing one before
      # its first job is a legitimate pre-deploy move for the same reason.
      def show(request)
        window = Page.window!(request)
        name = Validation.queue_name!(request.path_params[:name])
        snapshot = ::Wurk::Queue.new(name).snapshot(window.offset, window.count)
        jobs = snapshot.records.map { |record| Serializers.job_record(record) }
        Response.json(200, Serializers.queue_gauges(name, snapshot).merge(**window.to_h, jobs: jobs))
      end

      def retries(request) = sorted_set(request, ::Wurk::RetrySet.new)
      def scheduled(request) = sorted_set(request, ::Wurk::ScheduledSet.new)
      def dead(request) = sorted_set(request, ::Wurk::DeadSet.new)

      def pause(request) = toggle(request, paused: true)
      def unpause(request) = toggle(request, paused: false)

      # Idempotent both ways (SADD/SREM), and the resulting state comes back so
      # a client does not need a second request to confirm the toggle.
      def toggle(request, paused:)
        queue = ::Wurk::Queue.new(Validation.queue_name!(request.path_params[:name]))
        paused ? queue.pause! : queue.unpause!
        Response.json(200, name: queue.name, paused: paused)
      end

      # `total` and the page are one pipelined read, so the total describes the
      # set the page was taken from rather than the one left after a poller
      # drained it.
      def sorted_set(request, set)
        window = Page.window!(request)
        total, entries = set.snapshot(window.offset, window.count)
        jobs = entries.map { |entry| Serializers.sorted_entry(entry) }
        Response.json(200, name: set.name, total: total, page: window.page, count: window.count, jobs: jobs)
      end

      # Newest first, each row Batch::Status#summary: the failed and dead jid
      # sets counted rather than listed, so a page of 200 batches with 10k
      # failures each is not two million jids. `/batches/:bid` carries them.
      def batches(request)
        window = Page.window!(request)
        total, rows = ::Wurk::BatchSet.new.snapshot(window.offset, window.count)
        Response.json(200, total: total, page: window.page, count: window.count, batches: rows)
      end

      def batch(request)
        bid = Validation.bid!(request.path_params[:bid])
        status = ::Wurk::Batch::Status.new(bid)
        return batch_not_found(request, bid) unless status.exists?

        Response.json(200, status.data)
      end

      def batch_not_found(request, bid)
        Problem.render(
          Problem::BATCH_NOT_FOUND,
          status: 404,
          detail: "No batch has bid #{bid}; it was never created, or it has expired.",
          instance: request.path,
          bid: bid
        )
      end
    end
  end
end
