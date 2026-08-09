# frozen_string_literal: true

require_relative '../keys'
require_relative '../lua'

module Wurk
  class Flow
    # What a node finishing means for the rest of the graph.
    #
    # Registered as the `:success` and `:death` callback of every node's batch
    # at creation, so it arrives the way any batch callback does: as an ordinary
    # {Wurk::Batch::CallbackJob} on the flow's callback queue, retried like any
    # other job. Nothing polls, and nothing here counts a node's jobs — the
    # batch already knows when its own job is done, and this only answers what
    # the graph does next. That division is the whole design: a second
    # completion tracker is a second thing that can disagree with the first.
    #
    # Both answers are one Lua call, because both are races. `on_success` is the
    # sibling race — two dependencies of the same node finishing at once, where
    # reading "how many are left" and then deciding runs the parent twice or
    # never. `on_death` races the retry that saves it. Neither can be resolved
    # by this process, and neither tries: the scripts claim, and a callback that
    # runs twice writes once.
    #
    # @see lib/wurk/lua/flow_advance.lua
    # @see lib/wurk/lua/flow_fail.lua
    class Completion
      # A node succeeded. Release whatever was waiting only on it, and settle
      # the flow if it was the last node.
      #
      # The batch {Wurk::Batch::Status} the callback contract hands over says
      # nothing this needs: the node's address travels in the callback options,
      # written when the graph was created, and every fact about the graph is
      # read inside the script that acts on it. What comes back is the flow's
      # remaining node count — dropped, because the record already carries it —
      # then one class/queue pair per node the call released.
      def on_success(_status, options)
        fid, index = address(options)
        emit_enqueued(Array(advance(fid, index)).drop(1))
      end

      # A node's job died. Its dependents are not cancelled — they are simply
      # never released, because a batch holding a dead job never fires
      # `:success` — so all this does is make that visible on the flow record.
      # The claim decides whether this is news: a callback job redelivered
      # against an already-dead node has nothing to report.
      def on_death(_status, options)
        fid, index = address(options)
        return unless mark_dead(fid, index).to_i == 1

        Wurk.logger.warn("flow #{fid}: node #{index} died; nothing downstream of it will run")
      end

      private

      # `idempotent: true`, here and in {#mark_dead}, is the script's own claim
      # spent: a replay after a lost reply finds the node already out of the
      # state it claims from and writes nothing, so the pool may retry a
      # connection error rather than give up on a callback that fires once.
      def advance(fid, index)
        Wurk.redis(idempotent: true) do |conn|
          Wurk::Lua::Loader.eval_cached(
            conn, :flow_advance,
            keys: [Keys.flow(fid), 'queues'],
            argv: [index, now_seconds, now_millis]
          )
        end
      end

      def mark_dead(fid, index)
        Wurk.redis(idempotent: true) do |conn|
          Wurk::Lua::Loader.eval_cached(conn, :flow_fail, keys: [Keys.flow(fid)], argv: [index, now_seconds])
        end
      end

      # The callback options creation wrote. Coerced rather than validated: a
      # nonsense address resolves to a flow key nothing lives under, which the
      # scripts already refuse without writing.
      def address(options)
        [options['fid'].to_s, options['node'].to_i]
      end

      # A released node reaches its queue inside the script, so this is the
      # enqueue that counts it — {Wurk::Flow::Creation} deliberately counted
      # only the roots it queued. Same metric and same tags as
      # {Wurk::Client#emit_enqueued}, so a dashboard built for ordinary pushes
      # reads flow jobs without a second series.
      def emit_enqueued(pairs)
        return if Wurk::Metrics::Statsd.safe_client.nil?

        pairs.each_slice(2) do |klass, queue|
          Wurk::Metrics::Statsd.increment('jobs.enqueued', tags: ["worker:#{klass}", "queue:#{queue}"])
        end
      end

      def now_seconds = ::Process.clock_gettime(::Process::CLOCK_REALTIME).to_s
      def now_millis  = ::Process.clock_gettime(::Process::CLOCK_REALTIME, :millisecond)
    end
  end
end
