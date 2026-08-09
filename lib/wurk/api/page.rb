# frozen_string_literal: true

require 'rack'
require_relative 'validation'

module Wurk
  module API
    # Offset paging for the observe plane's listings.
    #
    # Deliberately not the dashboard's Wurk::Api::Pagination. That module is
    # autoloaded out of app/ by the engine, and the API has to page in
    # standalone mode where Rails is never loaded (CLAUDE.md); requiring an
    # autoloadable file by hand is exactly what Zeitwerk forbids. The contracts
    # differ too — the dashboard's may change whenever the SPA does, everything
    # under /v1 may not — so one shared module would tie a frozen contract to a
    # mutable one.
    module Page
      DEFAULT_COUNT = 25
      MAX_COUNT = 200

      # Offset paging reaches page N by walking N*count members through Ruby,
      # and their Redis round trips with them, so an unclamped `page` lets one
      # request drag an entire million-row set through this process. A
      # thousand pages is past any real client's depth and still bounds the
      # worst case.
      MAX_PAGE = 1_000

      Window = Data.define(:page, :count) do
        def offset = page * count
      end

      module_function

      # @raise [Validation::Invalid] when a paging parameter is present but is
      #   not an integer. Out of range is clamped instead of refused — a client
      #   asking for more rows than the API will give is not a client bug — and
      #   every listing echoes the effective values back, so the clamp is
      #   visible rather than silent.
      def window!(request)
        query = query!(request)
        Window.new(
          page: integer!(query['page'], 'page', 0).clamp(0, MAX_PAGE),
          count: integer!(query['count'], 'count', DEFAULT_COUNT).clamp(1, MAX_COUNT)
        )
      end

      # Rack::Request#params merges the POST body in, which the paged routes
      # must never read. parse_query is also flat: `?page[]=1` arrives as the
      # key it literally is instead of nesting into a Hash that reaches
      # Integer().
      #
      # Rack's own refusals (InvalidParameterError on bad %-encoding,
      # QueryLimitError on an oversized one) are ArgumentError and RangeError
      # respectively; caught here so a malformed query string is the 400 it is
      # rather than the 500 App's catch-all would make of it.
      def query!(request)
        ::Rack::Utils.parse_query(request.query_string)
      rescue ::ArgumentError, ::TypeError, ::RangeError
        raise Validation::Invalid, 'The query string could not be parsed.'
      end

      # A repeated parameter (`?page=1&page=2`) parses to an Array, which is
      # the TypeError arm — an ambiguous request, answered rather than guessed.
      def integer!(raw, name, default)
        return default if raw.nil? || raw == ''

        Integer(raw, 10)
      rescue ::ArgumentError, ::TypeError
        raise Validation::Invalid, "The '#{name}' parameter must be an integer."
      end

      # Walks `enumerable`, skips `window.offset` members, and hands at most
      # `window.count` of them to the block, which returns the row to emit.
      #
      # Skipped members are never yielded, so nothing before the offset is
      # serialized: on a queue page that is a JobRecord whose JSON is never
      # parsed, which is most of the cost of a deep page.
      def slice(enumerable, window)
        rows = []
        skipped = 0
        enumerable.each do |member|
          if skipped < window.offset
            skipped += 1
            next
          end

          rows << yield(member)
          break if rows.size >= window.count
        end
        rows
      end
    end
  end
end
