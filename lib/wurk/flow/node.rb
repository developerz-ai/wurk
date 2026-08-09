# frozen_string_literal: true

module Wurk
  class Flow
    # One node of a flow graph: a single job, plus the edges into and out of it.
    #
    # Deliberately not a payload. `klass`, `args` and `options` are held exactly
    # as the caller wrote them and normalized once, at creation, by
    # {Wurk::Client} — a node that pre-built its own job hash would be a second
    # definition of what a job hash is, and the two would drift.
    #
    # Built in two phases, because a name may be a forward reference (decision 5
    # in the slice plan): {Flow::Builder#job} constructs the node with the raw
    # `depends_on` refs it was given, and {#link!} replaces them with resolved
    # nodes once the whole block has run. Nothing outside the builder sees a
    # node between the two — {Flow} only ever receives frozen, linked ones.
    class Node
      # @return [Integer] declaration order, 0-based. The node's identity when
      #   it has no name: stable, and what creation orders writes by.
      attr_reader :index

      # @return [Symbol, nil] the name `depends_on:` can address this node by.
      attr_reader :name

      # @return [Class, String] the job class, as written.
      attr_reader :klass

      # @return [Array] positional `perform_async` arguments, as written.
      attr_reader :args

      # @return [Hash] job options merged into the payload at creation
      #   (`queue:`, `retry:`, `track:`, …). Not validated here: {Wurk::Client}
      #   owns what a valid option is, and duplicating that check would fork it.
      attr_reader :options

      # @return [Array] the raw `depends_on:` refs — nodes, names, or both.
      attr_reader :declared

      # @return [Node, Symbol, String, nil] the raw `pipe:` ref: the one
      #   dependency whose stored result is handed to this node as its last
      #   argument. nil for every ordinary node.
      attr_reader :pipe

      # @return [Array<Node>] resolved dependencies. This node runs after all
      #   of them succeed.
      attr_reader :dependencies

      # @return [Array<Node>] the nodes that depend on this one.
      attr_reader :dependents

      # @return [Integer] longest path from any root, 0-based. Assigned in
      #   topological order, so a node's level is final by the time it is read.
      attr_reader :level

      def initialize(index:, klass:, args:, options:, declared:, name: nil, pipe: nil)
        @index        = index
        @name         = name
        @klass        = klass
        @args         = args.freeze
        @options      = options.freeze
        @declared     = declared.freeze
        @pipe         = pipe
        @feeds_pipe   = false
        @dependencies = []
        @dependents   = []
        @level        = 0
      end

      def root? = @dependencies.empty?

      # @return [Boolean] true when this node is handed its dependency's stored
      #   result as its last argument.
      def piped? = !@pipe.nil?

      # @return [Node, nil] the dependency a piped node's argument comes from.
      #   The *only* dependency: {Flow::Builder} refuses `pipe:` on a node with
      #   more than one, because the graph is what makes "the upstream result"
      #   a single well-defined value (decision 2 in the slice plan).
      def source = @dependencies.first

      # @return [Boolean] true when some dependent pipes this node's result, so
      #   creation has to enqueue it with `track: true` — a node whose result
      #   nothing reads is not tracked, and tracking is opt-in per job.
      def feeds_pipe? = @feeds_pipe

      # Builder-only, between {#link!} and {#seal!}.
      def feeds_pipe!
        @feeds_pipe = true
        self
      end

      # Every error message in the builder ends up here, so it has to identify a
      # node in a thousand-node graph unambiguously: the class says what it is,
      # the name or index says which one.
      def label = "#{@klass}[#{@name ? @name.inspect : "##{@index}"}]"

      alias to_s label

      # Phase two of construction: adopt the resolved dependencies and register
      # this node as their dependent, so the graph is walkable in both
      # directions. Builder-only — a node linked twice would double its edges.
      def link!(nodes)
        @dependencies.concat(nodes)
        nodes.each { |node| node.dependents << self }
        self
      end

      def level!(value)
        @level = value
        self
      end

      # Shallow on purpose. The edge arrays and the node are sealed because the
      # graph is validated and must not change afterwards; `args` and `options`
      # are frozen at construction but their contents are the caller's, and
      # deep-freezing someone's argument objects is a side effect on their data.
      def seal!
        @dependencies.freeze
        @dependents.freeze
        freeze
      end
    end
  end
end
