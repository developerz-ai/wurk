# frozen_string_literal: true

require 'securerandom'
require_relative 'batch'
require_relative 'keys'
require_relative 'lua'

module Wurk
  # A DAG of jobs: fan out, fan in, and run each node only after everything it
  # depends on has succeeded. A Wurk extra — Sidekiq Pro has batches, which are
  # a flow exactly one level deep.
  #
  # @example A diamond — C runs once, after both A and B succeed
  #   Wurk::Flow.new do |f|
  #     a = f.job(FetchJob, 'https://a')
  #     b = f.job(FetchJob, 'https://b')
  #     f.job(MergeJob, depends_on: [a, b])
  #   end.run
  #
  # @example The same graph, addressed by name — forward references are legal
  #   Wurk::Flow.new do |f|
  #     f.job(MergeJob, name: :merge, depends_on: %i[a b])
  #     f.job(FetchJob, 'https://a', name: :a)
  #     f.job(FetchJob, 'https://b', name: :b)
  #   end
  #
  # A node is **one job, wrapped in its own batch**. That is the whole model:
  # a batch already owns success callbacks, the death cascade, subtree gating
  # and a rendered status, so a flow is the parent relation between batches and
  # not a second completion tracker. Two trackers that can disagree is the
  # failure mode of this feature.
  #
  # @example A chain — every step is handed the step before it
  #   Wurk::Flow.chain do |c|
  #     c.job(FetchJob, 'https://example.com')
  #     c.job(ParseJob)
  #     c.job(StoreJob, 'reports')
  #   end.run
  #
  # Work that is wide rather than deep belongs *inside* a node — that node's
  # job opens its own batch and enqueues however many children it likes, and
  # batch nesting already blocks the node on the whole subtree. Sibling nodes
  # are for work with different shapes, not for parallelism.
  #
  # Constructing a flow validates it and writes nothing. Every refusal happens
  # here, before Redis has heard of the graph: a cycle that would deadlock
  # silently, a name nothing declares, a graph past the caps below.
  #
  # Required eagerly from `wurk.rb`, unlike {Wurk::API} and {Wurk::Telemetry}
  # which load on opt-in: those buy back real pre-fork heap (1.2 MB) or depend
  # on a gem that may be absent, while this is three files of pure Ruby whose
  # load sits inside the run-to-run spread of `require "wurk"` (~250 ms ± 30).
  # Lazy-loading it would also put the `Sidekiq::Flow` alias behind a first use.
  #
  # @see Wurk::Flow::Builder for the declaration DSL and what it refuses.
  # @see docs/plans/2026/08/07/101-beyond-sidekiq/11-flows.md for why each of
  #   these answers is the one implemented.
  class Flow
    # Same generator and length as a batch's bid: URL-safe base64 of 10 random
    # bytes. A flow id is handled by the same code paths (dashboard routes, API
    # captures, log lines) and there is no reason for it to look different.
    FID_BYTES = 10

    # Total nodes. Creation is one atomic write, and Redis is single threaded —
    # the whole graph is that write's payload, and each node costs a batch's
    # keys. Beyond this the graph is not big, it is the wrong shape.
    MAX_NODES = 1_000

    # Longest dependency path. Each level costs a full callback hop — a job
    # finishing, a callback job enqueued, fetched and run — so depth is
    # latency; it is also how deep the batch death cascade recurses.
    MAX_DEPTH = 50

    # The most edges on either side of one node. Fan-in bounds how many
    # siblings race to advance the same parent; fan-out bounds how many nodes
    # a single completion enqueues.
    MAX_WIDTH = 100

    # The callback class every node's batch is created with, for both events a
    # node can reach: `:success` advances the flow, `:death` marks it failed.
    # Named here because creation writes the spec and {Flow::Completion} is what
    # answers to it; a literal in both places is a flow that stalls silently the
    # day one of them is renamed.
    COMPLETION_CALLBACK = 'Wurk::Flow::Completion'

    # Every build-time refusal. `ArgumentError` because a malformed graph is a
    # caller mistake in exactly the way a malformed job payload is — which also
    # means the HTTP API's existing rescue turns one into a 400 with no new arm.
    class InvalidGraph < ArgumentError; end

    # Raised when the graph is not acyclic. Carries the whole cycle path: the
    # node names alone do not tell you which edge to delete.
    class CycleError < InvalidGraph; end

    # Raised when the graph exceeds {MAX_NODES}, {MAX_DEPTH} or {MAX_WIDTH}.
    class LimitExceeded < InvalidGraph; end

    # @return [String] this flow's id. Allocated here and written to Redis by
    #   creation, the same way {Wurk::Batch} allocates a bid without a round
    #   trip — an unrun flow costs nothing but the object.
    attr_reader :fid

    # @return [Array<Flow::Node>] every node, frozen, in topological order.
    attr_reader :nodes

    # @return [Integer] number of levels — 1 for a flow with no edges.
    attr_reader :depth

    # @return [Integer] the most edges on either side of any one node.
    attr_reader :width

    # @return [Integer] seconds every key this flow creates lives for, absent
    #   the shorter clocks a finished batch stamps on its own keys.
    attr_reader :expiry

    # @return [Array<String>, nil] each node's jid, in node-index order, or nil
    #   before {#run}. A node is one job (decision 0), so this is the address
    #   of its result: `Wurk::Status.get(flow.jids[i])`.
    attr_reader :jids

    # @return [Array<String>, nil] each node's bid, in node-index order, or nil
    #   before {#run}. A node's batch is what carries its completion.
    attr_reader :bids

    # The queue every node batch's callbacks run on. Same knob and same default
    # as {Wurk::Batch#callback_queue}: a flow advances one callback at a time,
    # so a host that keeps callbacks off a saturated `default` needs to be able
    # to say so here too.
    attr_accessor :callback_queue

    class << self
      # A flow with one path through it: every step waits on the step before it
      # and is handed that step's stored return value as its last argument.
      #
      #   Wurk::Flow.chain do |c|
      #     c.job(FetchJob, 'https://example.com')
      #     c.job(ParseJob)                        # ParseJob#perform(fetch_result)
      #     c.job(StoreJob, 'reports')             # StoreJob#perform('reports', parse_result)
      #   end.run
      #
      # Every step but the last is enqueued with `track: true`, because the
      # pipe carries {Wurk::Status}'s stored result and tracking is opt-in per
      # job. A result too big to store — past
      # {Wurk::Middleware::Status::MAX_RESULT_BYTES} — stops the chain and
      # fails the flow rather than piping the truncated head: a shortened
      # display is lossy, a shortened *argument* is wrong.
      #
      # @see Flow::Chain
      def chain(&block)
        raise ArgumentError, 'flow requires a block' unless block

        new { |builder| block.call(Chain.new(builder)) }
      end

      # The kill switch: give up on a flow and release what it is holding.
      #
      # Marks the flow `abandoned` and drops every node record, every node
      # batch and the dead-node set — the ~9 keys per node that are the actual
      # weight. The flow's own record stays, on the clock it was created with,
      # because a flow that vanishes silently is indistinguishable from one
      # that was never created; `abandoned` is the answer to "where did it go".
      #
      # It does **not** chase in-flight jobs out of their queues. Same caveat
      # and same wording as {Wurk::Batch::Status#delete}: jobs already queued
      # will run and ack against a batch that is gone. Nothing they do can
      # revive the flow — every write in {Flow::Completion} claims on a node
      # record this released.
      #
      # Only a live flow can be abandoned. A flow that already succeeded, or
      # that was already abandoned, is not stuck and is left exactly as it is.
      #
      # `idempotent: true` is that claim spent: a replay after a lost reply
      # finds the flow already terminal and writes nothing, so the pool may
      # retry a connection error rather than give up on the kill switch. The
      # cost is that such a replay reports false for a call that did apply —
      # the flow record is the authority, not the return value.
      #
      # @return [Boolean] true when this call abandoned the flow.
      def abandon(fid) # rubocop:disable Naming/PredicateMethod
        now = ::Process.clock_gettime(::Process::CLOCK_REALTIME).to_s
        released = Wurk.redis(idempotent: true) do |conn|
          Wurk::Lua::Loader.eval_cached(
            conn, :flow_abandon,
            keys: [Keys.flow(fid), 'batches', 'dead-batches'],
            argv: [now, *Wurk::Batch::KEY_SUFFIXES]
          )
        end
        released.to_i >= 0
      end
    end

    def initialize(&block)
      raise ArgumentError, 'flow requires a block' unless block

      @fid = SecureRandom.urlsafe_base64(FID_BYTES)
      builder = Builder.new
      block.call(builder)
      @nodes = builder.build.freeze
      @depth = builder.depth
      @width = builder.width
      @expiry = Wurk::Batch::DEFAULT_EXPIRY_SECONDS
      @callback_queue = 'default'
      @created = false
    end

    def size = @nodes.size

    # @return [Array<Flow::Node>] the nodes with no dependencies — what
    #   creation enqueues immediately; everything else waits on a callback.
    def roots = @nodes.select(&:root?)

    # Retention for every key this flow creates, its nodes' batches included.
    # The batch clock (30 days) by default, because a flow is a relation
    # between batches and an abandoned one has to disappear the same way they
    # do — on its own, with no sweeper to elect a leader for.
    def expires_in(duration)
      @expiry = duration.to_i
      self
    end

    def created? = @created

    # Create the flow: persist the whole graph and enqueue the nodes that have
    # nothing to wait for, in one atomic write. Nothing before this touches
    # Redis, and a refusal here leaves nothing behind.
    #
    # The claim is taken before the write, not after it. A write whose reply is
    # lost may well have applied, and a second #run would build fresh jids only
    # to be turned away by the script's own claim — leaving this object
    # describing a flow that Redis does not have. One flow object creates one
    # flow; recovering from an ambiguous failure means building another.
    #
    # @return [self]
    def run
      raise "flow #{@fid} has already been created" if @created

      @created = true
      payloads = Creation.new(self).call
      @jids = payloads.map { |payload| payload['jid'] }.freeze
      @bids = payloads.map { |payload| payload['bid'] }.freeze
      self
    end

    # @return [Boolean] true when this call abandoned the flow.
    # @see Flow.abandon
    def abandon = self.class.abandon(@fid)
  end
end

require_relative 'flow/node'
require_relative 'flow/builder'
require_relative 'flow/chain'
require_relative 'flow/creation'
require_relative 'flow/completion'
