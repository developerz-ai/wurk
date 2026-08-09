# frozen_string_literal: true

require_relative 'problem'
require_relative 'response'
require_relative 'serializers'
require_relative 'validation'

module Wurk
  module API
    # One route: read a flow.
    #
    # A producer that posted a graph needs to know how far it got, and a fid is
    # the only thing it holds — so this answers by fid and nothing else. There
    # is no listing: the `flows` index is a dashboard affordance for a human
    # who lost an id, and paging a machine client through every flow in the
    # deployment is not a question a producer has.
    #
    # Nor is there a write. Abandonment is an operator decision made with the
    # graph on screen (slice 11 decision 4), and the dashboard is where that
    # screen is; a producer that could abandon its own flows over HTTP is one
    # bad retry away from killing a run that was merely slow.
    #
    # Reads through {Wurk::Flow::Status}, the same view the dashboard uses, for
    # the reason every other observe-plane route reads through an inspector: a
    # second reader of the flow key schema is a second thing to keep in step
    # with the completion scripts that write it.
    module Flows
      module_function

      TABLE = [
        [:get, '/flows/:fid', :read, :show]
      ].freeze

      def draw(router)
        TABLE.each do |verb, pattern, scope, handler|
          router.public_send(verb, pattern, scope: scope) do |request|
            public_send(handler, request)
          rescue Validation::Invalid => e
            Problem.from(e, instance: request.path)
          end
        end
      end

      def show(request)
        fid = Validation.fid!(request.path_params[:fid])
        status = ::Wurk::Flow::Status.new(fid)
        return not_found(request, fid) unless status.exists?

        Response.json(200, Serializers.flow(status))
      end

      # Expiry is named because it is the likeliest answer for a producer whose
      # fid used to work: a flow is kept on the batch clock and then goes, and
      # a client that assumed otherwise is the one reading this.
      def not_found(request, fid)
        Problem.render(
          Problem::FLOW_NOT_FOUND,
          status: 404,
          detail: "No flow has fid #{fid}; it was never created, or it has expired.",
          instance: request.path,
          fid: fid
        )
      end
    end
  end
end
