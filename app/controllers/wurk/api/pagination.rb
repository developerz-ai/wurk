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

      module_function

      def window(params)
        {
          page: [params[:page].to_i, 0].max,
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
      def slice(enumerable, page)
        results = []
        offset = page[:page] * page[:count]
        idx = 0
        enumerable.each do |member|
          if idx >= offset
            payload = yield(member)
            if payload && match?(payload, page[:substr])
              results << payload
              break if results.size >= page[:count]
            end
          end
          idx += 1
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
