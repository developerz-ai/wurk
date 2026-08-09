# frozen_string_literal: true

require 'securerandom'
require_relative '../job_util'
require_relative '../keys'
require_relative '../lua'

module Wurk
  class Flow
    # Turns a validated graph into Redis state: every node's payload, every
    # node's batch, and the queue entries for the nodes that can run now.
    #
    # Two phases, and the split is the point. Everything that can be refused —
    # a non-JSON argument, a queue-less class, a client middleware that halts
    # the push — happens while the graph is still only in memory. Only once
    # every node has a payload does anything reach Redis, and then all of it
    # does, in one script (`lua/flow_create.lua`). A flow that half exists
    # cannot be detected by the thing waiting on it: its parent simply never
    # fires, silently, forever.
    #
    # The accumulator is {Wurk::Batch::Buffer}, the same one an autoflush
    # `Batch#jobs` block fills, with a nil threshold — a batch buffers to
    # bound its pipeline and may flush early, whereas a flow has no legal
    # partial flush, and nil is how that is spelled.
    #
    # Payloads are built the way {Wurk::Client#push} builds one and for the
    # same reasons: {Wurk::JobUtil} normalizes and verifies, then the client
    # middleware chain runs. Every node's job goes through it — including the
    # ones this write only records — because a chain that ran for some nodes
    # and not others would produce a graph whose payloads disagree about what a
    # job of this app looks like.
    class Creation
      include Wurk::JobUtil

      # `state` on a node record. A node is `waiting` until every dependency has
      # succeeded; `enqueued` once its payload is on a queue. Creation writes
      # both — roots are enqueued, the rest wait — and the terminal states
      # belong to the completion step that owns those transitions.
      WAITING  = 'waiting'
      ENQUEUED = 'enqueued'

      # What a piped node carries in place of the argument it does not have
      # yet. The upstream result is not known until the upstream runs, so the
      # payload is stored with this sentinel where the argument goes and
      # `lua/flow_advance.lua` swaps the two bytes-for-bytes on the way to the
      # queue — no cjson round trip, which would round a 64-bit number in some
      # *other* argument to a double.
      #
      # It carries the fid and the node index so a sentinel is unique to the
      # one splice it belongs to, and so a payload caught in the dashboard mid
      # flow says what it is waiting for rather than showing a bare marker.
      PIPE_SENTINEL_PREFIX = 'wurk.flow.pipe:'

      def initialize(flow, config: nil)
        @flow   = flow
        @config = config || Wurk.configuration
      end

      # @return [Array<Hash>] every node's payload, in node-index order. The
      #   graph is in Redis by the time this returns.
      # @raise [Flow::InvalidGraph] a node's job cannot be enqueued as declared.
      def call
        payloads = build_payloads
        write(payloads)
        emit_enqueued(payloads)
        payloads
      end

      private

      def build_payloads
        buffer = Wurk::Batch::Buffer.new([], nil)
        without_enclosing_batch do
          @flow.nodes.each { |node| buffer.add([payload_for(node)]) }
        end
        payloads = by_node_index(buffer.drain)
        check_pipes!(payloads)
        payloads
      end

      # The one pipe refusal that needs a normalized payload to see, so it
      # cannot live in the builder with the rest: `encrypt` may come from the
      # job class's own `sidekiq_options` rather than from the node.
      #
      # An encrypted job's return value is deliberately never stored — storing
      # it would put back into a plaintext HASH exactly what enveloping the
      # args kept out of Redis (see Middleware::Status#withhold_result?) — so a
      # pipe from one can never carry anything. Refused here, before the write,
      # rather than at the release that would discover it minutes later.
      def check_pipes!(payloads)
        @flow.nodes.each do |node|
          next unless node.piped? && payloads[node.source.index]['encrypt']

          raise InvalidGraph, "#{node.label} pipes from #{node.source.label}, which declares encrypt: true; " \
                              'an encrypted job stores no result for a pipe to carry'
        end
      end

      # Built in topological order, handed back in declaration order. The two
      # differ the moment a `depends_on:` names a node declared later in the
      # block, and it is declaration order that addresses a node — `Node#index`
      # is what its record is keyed by and what its edges are written as, so a
      # caller reading `flow.jids[node.index]` has to find that node's job.
      def by_node_index(payloads)
        ordered = Array.new(payloads.size)
        @flow.nodes.each_with_index { |node, position| ordered[node.index] = payloads[position] }
        ordered
      end

      # A flow declared inside `batch.jobs { ... }` must not have its nodes
      # adopted by that batch: {Wurk::Batch::ClientMiddleware} stamps the active
      # batch's bid over whatever the payload carries, which would point every
      # node's acks at the enclosing batch and leave the node batches — the ones
      # holding the flow's callbacks — waiting on jobs that never arrive.
      def without_enclosing_batch
        previous = Thread.current[Wurk::Batch::THREAD_KEY]
        Thread.current[Wurk::Batch::THREAD_KEY] = nil
        yield
      ensure
        Thread.current[Wurk::Batch::THREAD_KEY] = previous
      end

      # The bid is set before the chain runs, not after, so middleware sees the
      # payload the job will actually carry. Nothing can take it away: the one
      # middleware that writes `bid` is disarmed above.
      def payload_for(node)
        item = node.options.transform_keys(&:to_s).merge(
          'class' => node.klass, 'args' => pipe_args(node), 'bid' => new_bid
        )
        # A node whose result something downstream pipes is tracked whether or
        # not the caller asked: the pipe reads Wurk::Status's row, and tracking
        # is opt-in per job. The builder has already refused the one case where
        # this would overrule the caller rather than fill in for them.
        item['track'] = true if node.feeds_pipe?
        normed = normalize_item(item)
        built  = @config.client_middleware.invoke(normed['class'], normed, normed['queue'], @config.redis_pool) do
          verify_json(normed)
          normed
        end
        built || refuse_halted(node)
      end

      # A halted node is a graph that cannot run: its dependents wait on a job
      # nothing will enqueue. Raised rather than dropped, and raised as an
      # InvalidGraph because the fix is in the declaration — a `collapse:` or a
      # unique lock on a node's class is the shape being refused.
      def refuse_halted(node)
        raise InvalidGraph,
              "#{node.label}: client middleware halted the push, so this node could never run"
      end

      def new_bid = SecureRandom.urlsafe_base64(Wurk::Batch::BID_BYTES)

      def pipe_args(node) = node.piped? ? [*node.args, pipe_sentinel(node)] : node.args

      def pipe_sentinel(node) = "#{PIPE_SENTINEL_PREFIX}#{@flow.fid}:#{node.index}"

      # `idempotent: true` is earned by the script's own claim: a replay after a
      # lost reply finds the flow key already there and writes nothing, so the
      # pool may retry a connection error that a non-idempotent write would have
      # to give up on.
      def write(payloads)
        keys = [Keys.flow(@flow.fid), Keys::FLOWS_SET, 'batches', 'queues']
        argv = script_argv(payloads)
        Wurk.redis(idempotent: true) do |conn|
          Wurk::Lua::Loader.eval_cached(conn, :flow_create, keys: keys, argv: argv)
        end
      end

      def script_argv(payloads)
        now = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
        cutoff, rank = Wurk::Batch.trim_bounds
        argv = [@flow.fid, now.to_s, @flow.expiry, @flow.depth, @flow.width,
                @flow.callback_queue, cutoff, rank]
        # Topological order, so the write reads the way the graph runs.
        @flow.nodes.each { |node| argv << envelope(node, payloads[node.index]) }
        argv
      end

      # One JSON object per node, every value a String. The job payload rides
      # inside it as a string rather than as nested JSON, so the script copies
      # the exact bytes this process built instead of decoding and re-encoding
      # arguments — a cjson round trip turns a 64-bit id into a double.
      #
      # `enqueued_at` marks arrival on an immediate queue, so only the nodes
      # this write actually queues carry one. A waiting node's stored payload
      # gets its stamp from the push that releases it.
      def envelope(node, payload)
        payload['enqueued_at'] = now_in_millis if node.root?
        Wurk.dump_json(node_fields(node, payload).merge(edge_fields(node)))
      end

      def node_fields(node, payload)
        json = Wurk.dump_json(payload)
        { 'i' => node.index.to_s, 'name' => node.name.to_s, 'class' => payload['class'],
          'queue' => payload['queue'], 'jid' => payload['jid'], 'bid' => payload['bid'],
          'state' => node.root? ? ENQUEUED : WAITING, 'payload' => json,
          'desc' => node.label, 'cb' => callbacks_json(node), 'pipe' => pipe_field(node, json) }
      end

      # Empty for an ordinary node, and the sentinel — exactly as it appears in
      # the stored bytes — for a piped one, which is both the flag the release
      # tests and the needle it splices at.
      #
      # Checked rather than assumed: a client middleware that rewrote `args`
      # would otherwise leave a node whose job runs with the wrong number of
      # arguments, or with a sentinel string where its input should be. Both
      # are silent, and the second is worse than not running at all.
      def pipe_field(node, json)
        return '' unless node.piped?

        sentinel = pipe_sentinel(node)
        return sentinel if json.scan("\"#{sentinel}\"").size == 1

        raise InvalidGraph, "#{node.label}: client middleware rewrote the argument its pipe writes into"
      end

      def edge_fields(node)
        { 'deps' => Wurk.dump_json(node.dependencies.map(&:index)),
          'dependents' => Wurk.dump_json(node.dependents.map(&:index)),
          'remaining' => node.dependencies.size.to_s }
      end

      # The callbacks a node batch is born with, in the triple shape `Batch#on`
      # writes. The flow advances on `:success` and only on `:success`, because
      # a batch holding a dead job fires `:complete` but never `:success`
      # (decision 1 — the dependents of a dead node simply never run).
      #
      # `:death` adds nothing to that gate; it is what stops the flow record
      # from reading `running` forever once a node can no longer move.
      def callbacks_json(node)
        options = { 'fid' => @flow.fid, 'node' => node.index }
        Wurk.dump_json([['success', COMPLETION_CALLBACK, options], ['death', COMPLETION_CALLBACK, options]])
      end

      # Only the roots. `jobs.enqueued` counts jobs put on a queue, and the rest
      # of the graph is recorded, not queued — its own enqueue is what counts it.
      # Mirrors the tags {Wurk::Client#emit_enqueued} uses so a dashboard built
      # for ordinary pushes reads flow jobs without a second series.
      def emit_enqueued(payloads)
        return if Wurk::Metrics::Statsd.safe_client.nil?

        @flow.nodes.each do |node|
          next unless node.root?

          payload = payloads[node.index]
          Wurk::Metrics::Statsd.increment(
            'jobs.enqueued', tags: ["worker:#{payload['class']}", "queue:#{payload['queue']}"]
          )
        end
      end
    end
  end
end
