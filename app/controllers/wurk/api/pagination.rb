# frozen_string_literal: true

module Wurk
  module Api
    # Pagination helpers shared by every listing endpoint. The contract:
    #   * `?count=` page size (default 25, clamped to 1..200)
    #   * `?page=`  0-indexed page number
    #   * `?substr=` case-insensitive klass/jid filter on the page
    #
    # Helpers expect an Enumerable that yields whatever JSON-shaped Hash the
    # caller built; substr filtering and slicing happen after serialization so
    # filters work on the same fields the UI reads.
    module Pagination
      DEFAULT_PAGE_SIZE = 25
      MAX_PAGE_SIZE = 200
      # Offset pagination reaches page N by walking N*count rows through Ruby
      # (and their Redis round-trips). An unclamped ?page= lets one request
      # walk an entire million-row set; 1000 pages is far beyond any real UI
      # depth while bounding the worst-case walk.
      MAX_PAGE = 1_000
      # A substr that matches nothing would otherwise stream the whole backing
      # set through Ruby (same DoS shape Web::Search bounds with SCAN_BUDGET).
      # Raw rows examined per filtered request; results within the budget are
      # exact, beyond it the page just comes back short.
      FILTER_SCAN_LIMIT = 20_000

      module_function

      def window(params)
        {
          page: clamp_int(params[:page], 0, MAX_PAGE, 0),
          count: clamp_int(params[:count], 1, MAX_PAGE_SIZE, DEFAULT_PAGE_SIZE),
          substr: params[:substr].to_s
        }
      end

      def clamp_int(value, min, max, default)
        Integer(value, 10).clamp(min, max)
      rescue ::ArgumentError, ::TypeError
        default
      end

      def clamp_float(value, min, max, default)
        Float(value).clamp(min, max)
      rescue ::ArgumentError, ::TypeError
        default
      end

      # Iterates `enumerable` and collects up to `count` payloads from the
      # requested page after substr filtering. `block` maps each member to a
      # JSON Hash; nil from the block skips the member entirely.
      #
      # With a substr filter the offset must count *matching* rows, not raw
      # rows — otherwise page N restarts at raw index N*count and re-emits
      # (or skips) matches already assigned to earlier pages. Without a
      # filter we keep the fast path that skips serialization before the
      # offset.
      def slice(enumerable, page, &)
        offset = page[:page] * page[:count]
        if page[:substr].empty?
          slice_raw(enumerable, offset, page[:count], &)
        else
          slice_filtered(enumerable, offset, page, &)
        end
      end

      # Fast path: skip serialization entirely for rows before the offset.
      def slice_raw(enumerable, offset, count)
        results = []
        seen = 0
        enumerable.each do |member|
          if seen < offset
            seen += 1
            next
          end

          payload = yield(member)
          next unless payload

          results << payload
          break if results.size >= count
        end
        results
      end

      # Filtered path: the offset counts MATCHING rows, so page boundaries
      # stay stable (raw-index offsets re-emit or skip matches across pages).
      def slice_filtered(enumerable, offset, page)
        results = []
        matched = 0
        examined = 0
        enumerable.each do |member|
          examined += 1
          break if examined > FILTER_SCAN_LIMIT

          payload = yield(member)
          next unless payload && match?(payload, page[:substr])

          if matched >= offset
            results << payload
            break if results.size >= page[:count]
          end
          matched += 1
        end
        results
      end

      def match?(payload, substr)
        return true if substr.nil? || substr.empty?

        needle = substr.downcase
        payload[:klass].to_s.downcase.include?(needle) || payload[:jid].to_s.downcase.include?(needle)
      end
    end
  end
end
