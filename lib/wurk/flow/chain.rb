# frozen_string_literal: true

module Wurk
  class Flow
    # A flow with one path through it, where every step is handed the step
    # before it.
    #
    #   Wurk::Flow.chain do |c|
    #     c.job(FetchJob, 'https://example.com')
    #     c.job(ParseJob)                          # gets FetchJob's result
    #     c.job(StoreJob, 'reports')               # gets ParseJob's result
    #   end.run
    #
    # No new machinery: this is {Flow::Builder}'s `pipe:` applied to the node
    # before, once per step. Everything a flow does — atomic creation, the
    # caps, failure propagation, `abandon` — applies unchanged, and a chain is
    # inspectable as the graph it is rather than as a second kind of object.
    #
    # The argument arrives last, after whatever the step declared for itself:
    # `c.job(StoreJob, 'reports')` runs `StoreJob#perform('reports', result)`.
    # Prepending it would mean a step's own arguments change position depending
    # on where in the chain it sits.
    class Chain
      def initialize(builder)
        @builder  = builder
        @previous = nil
      end

      # Add the next step.
      #
      # @return [Flow::Node] the step, usable as a `depends_on:` elsewhere in
      #   the same block — a chain is still a graph, so a branch off it is
      #   legal and is what the underlying {Flow::Builder} would have built.
      # `pipe: nil` on the first step is exactly `pipe:` not being passed —
      # {Flow::Builder#job} treats them the same — so there is no first-step
      # branch to get wrong.
      def job(klass, *, **)
        @previous = @builder.job(klass, *, pipe: @previous, **)
      end
    end
  end
end
