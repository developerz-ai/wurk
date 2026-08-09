# frozen_string_literal: true

require 'json'
require_relative '../keys'

module Wurk
  class Flow
    # A created flow, read back. The counterpart of {Wurk::Batch::Status}, and
    # the only reader of the flow key schema: the dashboard controller and the
    # machine API both go through this, so the two surfaces cannot disagree
    # about what state a flow is in.
    #
    # Everything here is a snapshot taken at construction — the header in one
    # round trip, the nodes in a second, and only if something asks for them. A
    # listing walks header fields alone (`state`, `pending`, `created_at`), so
    # it never pays for a thousand node records it will not render.
    #
    # The stored job payload is deliberately not among the fields read. It is
    # the largest thing on a node record, it is the one field that carries the
    # caller's own arguments, and neither surface renders it — the node's jid
    # is what addresses the job, and every job-inspection view already exists.
    class Status
      # Every node field except `payload`. Ordered as {Flow::Creation} writes
      # them, so the two lists read as the same record.
      NODE_FIELDS = %w[index name class queue jid bid state deps dependents remaining pipe error].freeze

      # A flow is `running` until it is one of the other three. `failed` is not
      # terminal — retrying a dead node out of the morgue puts the flow back to
      # `running` — which is why it is not listed as such anywhere.
      TERMINAL_STATES = %w[succeeded abandoned].freeze

      attr_reader :fid

      def initialize(fid)
        raise ArgumentError, 'fid required' if fid.nil? || fid.to_s.empty?

        @fid = fid.to_s
        reload!
      end

      # False when no `flow:<fid>` hash exists: a well-formed fid that was
      # never created, or whose retention ran out. Abandoning a flow leaves the
      # record behind on purpose, so an abandoned flow still exists here.
      def exists? = !@header.empty?

      def state       = @header['state']
      def total       = @header['total'].to_i
      def pending     = @header['pending'].to_i
      def depth       = @header['depth'].to_i
      def width       = @header['width'].to_i
      def expiry      = @header['expiry'].to_i
      def created_at  = numeric_or_nil(@header['created_at'])
      def finished_at = numeric_or_nil(@header['finished_at'])
      def failed_at   = numeric_or_nil(@header['failed_at'])
      def abandoned_at = numeric_or_nil(@header['abandoned_at'])

      def running?   = state == 'running'
      def succeeded? = state == 'succeeded'
      def failed?    = state == 'failed'
      def abandoned? = state == 'abandoned'

      # @return [Boolean] true when nothing will move this flow again. A failed
      #   flow can still recover, so it is not one of these.
      def terminal? = TERMINAL_STATES.include?(state)

      # @return [Integer] nodes that have succeeded. Derived rather than
      #   stored: `pending` is the counter the completion script decrements,
      #   and a second field for its complement is a second thing to keep true.
      def succeeded_count = total - pending

      # @return [Array<Integer>] the nodes the flow is failed because of —
      #   whose job reached the morgue, or whose pipe had nothing to carry.
      #   Empty for a healthy flow, and empty after abandonment, which drops
      #   the set along with the node records it points into.
      def dead_indexes
        @dead_indexes ||= Wurk.redis { |conn| conn.call('SMEMBERS', Keys.flow_dead(@fid)) }.map(&:to_i).sort
      end

      # @return [Array<Node>] every node, in declaration order. Empty for an
      #   abandoned flow: the kill switch releases the node records, and their
      #   absence is the honest reading of "there is nothing left to show".
      def nodes
        @nodes ||= read_nodes
      end

      # JSON-serializable snapshot. Node rows ride inside it because a flow
      # without its nodes is a progress bar — the graph is the thing being
      # asked for, and a second round of requests to assemble it would race the
      # first.
      def data
        {
          'fid' => @fid, 'state' => state, 'total' => total, 'pending' => pending,
          'succeeded' => succeeded_count, 'depth' => depth, 'width' => width,
          'created_at' => created_at, 'finished_at' => finished_at, 'failed_at' => failed_at,
          'abandoned_at' => abandoned_at, 'dead_nodes' => dead_indexes,
          'nodes' => nodes.map(&:data)
        }
      end

      def reload!
        raw = Wurk.redis { |conn| conn.call('HGETALL', Keys.flow(@fid)) }
        @header = raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
        @nodes = nil
        @dead_indexes = nil
        self
      end

      # One node of the graph, as stored. Reads only — {Flow::Builder}'s Node is
      # the declaration-side object and holds the caller's arguments; this one
      # holds what Redis has, which is the part that changes as the flow runs.
      class Node
        STATES = %w[waiting enqueued succeeded dead broken].freeze

        attr_reader :index, :name, :klass, :queue, :jid, :bid, :state,
                    :dependencies, :dependents, :remaining, :error

        def initialize(fields)
          read_identity(fields)
          read_edges(fields)
          read_progress(fields)
        end

        # @return [Boolean] true when this node is handed its dependency's
        #   stored result. The sentinel itself is not published: it is an
        #   internal splice marker, and its bytes say nothing a reader wants.
        def piped? = @piped

        def data
          {
            'index' => @index, 'name' => @name, 'class' => @klass, 'queue' => @queue,
            'jid' => @jid, 'bid' => @bid, 'state' => @state, 'depends_on' => @dependencies,
            'dependents' => @dependents, 'remaining' => @remaining, 'piped' => @piped,
            'error' => @error
          }
        end

        private

        # Split along the seam the record itself has: creation wrote the first
        # two groups once and never touches them again.
        def read_identity(fields)
          @index = fields['index'].to_i
          @name  = presence(fields['name'])
          @klass = fields['class']
          @queue = fields['queue']
          @jid   = fields['jid']
          @bid   = fields['bid']
        end

        def read_edges(fields)
          @dependencies = parse_indexes(fields['deps'])
          @dependents   = parse_indexes(fields['dependents'])
          @piped        = !fields['pipe'].to_s.empty?
        end

        # The third is what the completion scripts move as the flow runs.
        def read_progress(fields)
          @state     = fields['state']
          @remaining = fields['remaining'].to_i
          @error     = presence(fields['error'])
        end

        def presence(value) = value.nil? || value.empty? ? nil : value

        # Degrades rather than raises, the same way {Wurk::Batch::Status#tags}
        # does over the same kind of field. This is the read side of an
        # observability surface: a node whose edge list someone corrupted is
        # worth showing without its edges, and is not worth taking the other
        # 999 nodes down with.
        def parse_indexes(raw)
          return [] if raw.nil? || raw.empty?

          JSON.parse(raw).map(&:to_i)
        rescue JSON::ParserError
          []
        end
      end

      private

      # One pipeline for the whole graph — at {Flow::MAX_NODES} that is 1,000
      # HMGETs in one round trip, against 1,000 round trips for the obvious
      # loop. `total` is the flow's own count, so this cannot be talked into a
      # bigger read than the flow it was asked about.
      def read_nodes
        rows = Wurk.redis do |conn|
          conn.pipelined do |pipe|
            total.times { |i| pipe.call('HMGET', Keys.flow_node(@fid, i), *NODE_FIELDS) }
          end
        end
        rows.filter_map { |row| Node.new(NODE_FIELDS.zip(row).to_h) if row.first }
      end

      # "No timestamp" and "a timestamp nothing can read" are the same answer to
      # a caller rendering a clock — and the same reason {#parse_indexes} gives
      # for not raising out of a read.
      def numeric_or_nil(value)
        return nil if value.nil? || value.to_s.empty?

        Float(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
