# frozen_string_literal: true

module Wurk
  class Web
    # `page` / `page_items`, the pagination extensions call from their routes and
    # that `Sidekiq::Paginator` names. The dashboard paginates through its JSON
    # API, so nothing but extensions reaches this.
    module Paginator
      # @return [Array(Integer, Integer, Array)] the page served, the collection's
      #   size and the items. A sorted set yields `[member, score]` pairs; a list
      #   yields members. A missing key is an empty first page.
      def page(key, pageidx = 1, page_count = 25, opts = nil)
        current = [pageidx.to_i, 1].max
        first = (current - 1) * page_count
        last = first + page_count - 1
        ::Wurk.redis do |conn|
          case conn.call('TYPE', key)
          when 'zset' then [current, conn.call('ZCARD', key), sorted_page(conn, key, first, last, opts)]
          when 'list' then [current, conn.call('LLEN', key), list_page(conn, key, first, last, opts)]
          when 'none' then [1, 0, []]
          else raise ::ArgumentError, "can't paginate #{key}: it is neither a sorted set nor a list"
          end
        end
      end

      # Paginates an in-memory collection.
      def page_items(items, pageidx = 1, page_count = 25)
        current = [pageidx.to_i, 1].max
        rows = items.to_a
        [current, rows.size, rows.slice((current - 1) * page_count, page_count) || []]
      end

      private

      def list_page(conn, key, first, last, opts)
        return conn.call('LRANGE', key, first, last) unless opts && opts[:reverse]

        conn.call('LRANGE', key, -(last + 1), -(first + 1)).reverse
      end

      def sorted_page(conn, key, first, last, opts)
        command = opts && opts[:reverse] ? 'ZREVRANGE' : 'ZRANGE'
        rows = conn.call(command, key, first, last, 'WITHSCORES')
        rows = rows.each_slice(2).to_a unless rows.first.is_a?(::Array)
        rows.map { |member, score| [member, score.to_f] }
      end
    end
  end
end
