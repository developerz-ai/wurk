# frozen_string_literal: true

module Wurk
  class Flow
    # Declares a flow graph and proves it is one.
    #
    # Everything here runs before a single key is written. A DAG builder that
    # accepts a cycle deadlocks silently — the parent waits on a dependency
    # that is waiting on the parent, nothing raises, and the flow simply never
    # finishes. The same is true of an unbounded graph, which does not fail so
    # much as bury Redis. So both are refused here, loudly, naming the node.
    #
    # Validation happens in one pass at {#build}, not incrementally, because a
    # name may be a forward reference: `depends_on: :merge` is legal before
    # `name: :merge` is declared (decision 5 in the slice plan), and that is
    # precisely what makes a cycle expressible and this check load-bearing.
    #
    # What is *not* checked here: whether the job class exists, whether its
    # arguments are JSON-native, whether its options are ones Wurk knows.
    # {Wurk::Client} owns all three at creation, and a second copy of that
    # check is a second thing to keep in sync.
    class Builder
      # @return [Integer] number of levels in the graph, longest path first.
      #   Set by {#build}; reading it before then is meaningless.
      attr_reader :depth

      # @return [Integer] the most edges on either side of any one node.
      attr_reader :width

      def initialize
        @nodes   = []
        @by_name = {}
        @depth   = 0
        @width   = 0
      end

      # Declare one job.
      #
      # @param klass [Class, String] the job class.
      # @param args [Array] positional `perform_async` arguments.
      # @param name [Symbol, String, nil] a name other nodes may depend on,
      #   including from earlier in the block.
      # @param depends_on [Node, Symbol, String, Array, nil] what must succeed
      #   before this node runs — handles returned by earlier `#job` calls,
      #   names, or a mix.
      # @param options [Hash] job options (`queue:`, `retry:`, `track:`, …),
      #   merged into the payload at creation.
      # @return [Node] a handle, usable as another node's `depends_on:`.
      def job(klass, *args, name: nil, depends_on: nil, **options)
        validate_class!(klass)
        key = register_name!(name)
        check_size!(klass)
        node = Node.new(index: @nodes.size, name: key, klass: klass, args: args,
                        options: options, declared: refs(depends_on))
        @nodes << node
        @by_name[key] = node if key
        node
      end

      # Resolve, validate and seal the graph.
      #
      # @return [Array<Node>] every node, in topological order — dependencies
      #   before dependents, declaration order among equals, so creation and
      #   every error message read in the order the caller wrote them.
      # @raise [Flow::InvalidGraph] the graph is not one.
      def build
        raise InvalidGraph, 'a flow must declare at least one job' if @nodes.empty?

        link!
        order = topological_order
        measure!(order)
        check_depth!(order)
        check_width!(order)
        order.each(&:seal!)
        order
      end

      private

      def refs(depends_on)
        case depends_on
        when nil   then []
        when Array then depends_on
        else            [depends_on]
        end
      end

      # A node with no job class is not a node, and its {Node#label} — which
      # every later error message is built from — would be unreadable. The
      # payload-level checks stay with Client; this one is about the graph
      # being describable at all.
      def validate_class!(klass)
        return if klass.is_a?(Class) || (klass.is_a?(String) && !klass.empty?)

        raise InvalidGraph, "flow job class must be a Class or a non-empty String: #{klass.inspect}"
      end

      def register_name!(name)
        return nil if name.nil?
        raise InvalidGraph, "flow node name must be a Symbol or String: #{name.inspect}" unless nameable?(name)

        key = name.to_sym
        raise InvalidGraph, "duplicate flow node name #{key.inspect}" if @by_name.key?(key)

        key
      end

      def nameable?(name)
        (name.is_a?(Symbol) || name.is_a?(String)) && !name.to_s.empty?
      end

      def check_size!(klass)
        return if @nodes.size < MAX_NODES

        raise LimitExceeded, "#{klass} would be flow node #{@nodes.size + 1}; MAX_NODES is #{MAX_NODES}"
      end

      # `.uniq` collapses a repeated dependency rather than raising on it:
      # `depends_on: [a, a]` says "after a" twice, which is one edge, and
      # letting it through as two would double the node's fan-in against the
      # width cap and its ack count against the completion check.
      def link!
        @nodes.each { |node| node.link!(node.declared.map { |ref| resolve(ref, node) }.uniq) }
      end

      def resolve(ref, node)
        case ref
        when Node           then own(ref, node)
        when Symbol, String then named(ref.to_sym, node)
        else
          raise InvalidGraph,
                "#{node.label}: depends_on takes nodes returned by #job or their names, got #{ref.inspect}"
        end
      end

      # Identity, not equality: two flows can hold structurally identical nodes,
      # and an edge to the other flow's copy would resolve to a node this graph
      # never runs — a parent waiting forever on something nothing will finish.
      def own(ref, node)
        return ref if @nodes[ref.index].equal?(ref)

        raise InvalidGraph, "#{node.label} depends on #{ref.label}, which belongs to a different flow"
      end

      def named(key, node)
        @by_name.fetch(key) do
          raise InvalidGraph, "#{node.label} depends on #{key.inspect}, which no node declares"
        end
      end

      # Kahn's algorithm: it yields the creation order and the cycle check in
      # one pass, and its leftovers are exactly the nodes involved in — or
      # downstream of — a cycle, which is what names one in the error.
      def topological_order
        order = drain(@nodes.select(&:root?), @nodes.to_h { |node| [node, node.dependencies.size] })
        raise CycleError, cycle_message(order) if order.size < @nodes.size

        order
      end

      # A node becomes ready the moment its last dependency is emitted, and not
      # before: the indegree gate is what makes this a topological order rather
      # than a walk that visits a fan-in node once per parent.
      def drain(ready, indegree)
        order = []
        until ready.empty?
          node = ready.shift
          order << node
          node.dependents.each do |dependent|
            indegree[dependent] -= 1
            ready << dependent if indegree[dependent].zero?
          end
        end
        order
      end

      def cycle_message(order)
        path = cycle_path(Set.new(@nodes) - order)
        "flow has a dependency cycle: #{path.map(&:label).join(' → ')} (→ reads \"depends on\")"
      end

      # Walk dependencies until a node repeats, then keep the loop and drop the
      # approach path — deleting an edge that only leads *into* a cycle fixes
      # nothing. Every node left unemitted has at least one dependency that was
      # also unemitted, which is why its indegree never reached zero, so the
      # walk cannot dead end; with a finite set it must close on itself.
      def cycle_path(stuck)
        seen = {}
        node = stuck.first
        until seen.key?(node)
          seen[node] = seen.size
          node = node.dependencies.find { |dependency| stuck.include?(dependency) }
        end
        seen.keys[seen[node]..] + [node]
      end

      # Levels in topological order, so every dependency already has its own by
      # the time a node reads them. Longest path, not shortest: a node waits on
      # its slowest branch, and the depth cap is about how many callback hops
      # the flow takes end to end.
      def measure!(order)
        order.each { |node| node.level!(node.dependencies.map(&:level).max&.succ || 0) }
        @depth = order.map(&:level).max + 1
        @width = order.map { |node| widest(node) }.max
      end

      def widest(node) = [node.dependencies.size, node.dependents.size].max

      def check_depth!(order)
        return if @depth <= MAX_DEPTH

        raise LimitExceeded, "flow depth #{@depth} exceeds MAX_DEPTH (#{MAX_DEPTH}); " \
                             "the longest path ends at #{order.max_by(&:level).label}"
      end

      # The message has to say where the work belongs, not just that it was
      # refused: a wide fan-in is a modelling mistake, and the fix is one node
      # whose own job opens a batch, which the nesting machinery already gates
      # the flow on.
      def check_width!(order)
        return if @width <= MAX_WIDTH

        node  = order.find { |n| widest(n) > MAX_WIDTH }
        side  = node.dependencies.size > MAX_WIDTH ? 'dependencies' : 'dependents'
        count = widest(node)
        raise LimitExceeded, "#{node.label} has #{count} #{side}; MAX_WIDTH is #{MAX_WIDTH}. " \
                             "Work that wide belongs inside one node's own batch, not as #{count} sibling nodes."
      end
    end
  end
end
