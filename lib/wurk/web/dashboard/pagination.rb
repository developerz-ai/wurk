# frozen_string_literal: true

module Wurk
  module Api
    # Pagination helpers shared by every listing endpoint. The contract:
    #   * `?count=` page size (default 25, clamped to 1..200)
    #   * `?page=`  0-indexed page number
    #   * `?substr=` case-insensitive filter on a row's klass, jid, error
    #     class, error message or args
    #
    # Helpers expect an Enumerable that yields whatever JSON-shaped Hash the
    # caller built; substr filtering and slicing happen after serialization so
    # filters work on the same fields the UI reads.
    module Pagination
      DEFAULT_PAGE_SIZE = 25
      MAX_PAGE_SIZE = 200
      # An unfiltered listing reads its page at the offset (the set's
      # #snapshot), whatever the depth; the walks that remain (a filtered
      # #slice, the Limits names) still pay per skipped row, and 1000 pages is
      # far beyond any real UI depth while bounding them.
      MAX_PAGE = 1_000
      # A substr that matches nothing would otherwise stream the whole backing
      # set through Ruby, so a filtered request examines at most Web::Search's
      # per-request budget of raw rows; results within it are exact, beyond it
      # the page just comes back short.
      FILTER_SCAN_LIMIT = ::Wurk::Web::Search::SCAN_BUDGET
      # A filter walk reads the set through its #snapshot, starting at an
      # ordinary listing page and doubling to FILTER_PAGE: a match near the
      # top costs what it did, and the full budget costs ~25 round trips
      # rather than one per 50 rows.
      FIRST_FILTER_PAGE = 50
      FILTER_PAGE = 1_000
      # Entries one filtered `<set>/all/:cmd` request acts on, the cap the
      # bulk `keys[]` action already has.
      SWEEP_LIMIT = 1_000
      MATCHED_FIELDS = %i[klass jid error_class error_message].freeze

      module_function

      def window(params)
        {
          page: clamp_int(params[:page], 0, MAX_PAGE, 0),
          count: clamp_int(params[:count], 1, MAX_PAGE_SIZE, DEFAULT_PAGE_SIZE),
          substr: params[:substr].to_s
        }
      end

      # The paging fields every listing answers with. `page` is the page
      # actually served (an out-of-range ?page= is clamped, so the SPA must
      # adopt it) and `max_page` the deepest page the server will walk to.
      # A filtered slice adds `filtered_total` — matching rows found — and
      # `filtered_total_exact`; when false the count is a lower bound.
      def meta(page)
        fields = { page: page[:page], count: page[:count], max_page: MAX_PAGE }
        return fields unless page.key?(:matched)

        fields.merge(filtered_total: page[:matched], filtered_total_exact: page[:exhausted])
      end

      # Rows before the requested page: where an unfiltered listing reads from.
      def offset(page) = page[:page] * page[:count]

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

      # One page of a filtered listing: up to `count` payloads (the block maps
      # each member to one; nil skips it) from the matches of `substr`, in
      # `enumerable`'s order. The offset counts MATCHING rows, so page
      # boundaries stay stable (raw-index offsets re-emit or skip matches
      # across pages). Records the matches seen in `page[:matched]` and whether
      # the set was walked to its end in `page[:exhausted]`: stopping once the
      # page fills is what keeps a filtered request cheap, so the count is only
      # exact when nothing was left unread.
      def slice(enumerable, page)
        results = []
        matched = 0
        examined = 0
        enumerable.each do |member|
          break if (examined += 1) > FILTER_SCAN_LIMIT

          payload = yield(member)
          next unless payload && match?(payload, page[:substr])

          results << payload if (matched += 1) > offset(page)
          break if results.size >= page[:count]
        end
        record_match_count(page, matched, examined, results.size)
        results
      end

      def record_match_count(page, matched, examined, served)
        page[:matched] = matched
        page[:exhausted] = examined <= FILTER_SCAN_LIMIT && served < page[:count]
      end

      # Up to SWEEP_LIMIT of `rows`' members whose row (the block maps a member
      # to it) matches `substr`, within FILTER_SCAN_LIMIT examined:
      # [members, rows examined, whether `rows` ran out].
      def matching(rows, substr)
        members = []
        examined = 0
        rows.each do |member|
          return [members, examined, false] if examined >= FILTER_SCAN_LIMIT || members.size >= SWEEP_LIMIT

          examined += 1
          members << member if match?(yield(member), substr)
        end
        [members, examined, true]
      end

      # Every row from raw offset `from` on, read page by page through the
      # block, which answers `count` rows from `offset` in listing order.
      # Stops after the first short page.
      def walk(from = 0, &read)
        ::Enumerator.new do |out|
          offset = from
          size = FIRST_FILTER_PAGE
          loop do
            rows = read.call(offset, size)
            rows.each { |row| out << row }
            break if rows.size < size

            offset += size
            size = [size * 2, FILTER_PAGE].min
          end
        end
      end

      def match?(payload, substr)
        return true if substr.nil? || substr.empty?

        needle = substr.downcase
        MATCHED_FIELDS.any? { |field| payload[field].to_s.downcase.include?(needle) } ||
          args_match?(payload[:args], needle)
      end

      # Against the args as the SPA shows them: JSON, so `"a@b.c"` or `42]`
      # match as typed.
      def args_match?(args, needle)
        !args.nil? && ::Wurk.dump_json(args).downcase.include?(needle)
      end
    end
  end
end
