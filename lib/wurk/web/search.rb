# frozen_string_literal: true

require_relative '../queue'
require_relative '../retry_set'
require_relative '../scheduled_set'
require_relative '../dead_set'

module Wurk
  class Web
    # Pro feature parity: substring search across queues / retries /
    # scheduled / dead. Spec: docs/target/sidekiq-pro.md §10.1 ("Search box
    # on Retry/Scheduled/Dead pages, substring across job payload via ZSCAN").
    # Wurk ships it free, extended to also cover the queue LIST.
    #
    # ZSET stores are ZSCAN-paged and filtered client-side against the literal
    # substring — the same shape as the queue LIST's paged LRANGE filter —
    # rather than `ZSCAN MATCH`: MATCH returns only matches, never the count of
    # elements Redis walked, so a no-match keystroke couldn't be metered and
    # could round-trip an enormous ZSET. Both paths charge the shared scan
    # budget so a keystroke never full-walks a multi-million-entry store.
    #
    # Result shape mirrors `Wurk::Api::Serializers#sorted_entry` so the SPA
    # renders search hits with the same component as a sorted-set row.
    class Search
      DEFAULT_LIMIT = 100
      MAX_LIMIT = 500
      KINDS = %w[queues retry scheduled dead].freeze
      QUEUE_PAGE = 50
      ZSCAN_PAGE = 200
      # A queue LIST has no SCAN, so a keystroke must never full-walk a
      # multi-million-entry queue. Bound each queue's scan and the whole
      # request's scan; `truncated?` flips when we stop early so the API can
      # tell the UI it's showing partial results.
      SCAN_LIMIT_PER_QUEUE = 5_000
      SCAN_BUDGET = 20_000

      attr_reader :substring, :kinds, :limit

      def initialize(substring, kinds: KINDS, limit: DEFAULT_LIMIT)
        @substring = substring.to_s
        @kinds = (Array(kinds).map(&:to_s) & KINDS)
        @kinds = KINDS.dup if @kinds.empty?
        @limit = limit.to_i.clamp(1, MAX_LIMIT)
        @truncated = false
        @scanned = 0
      end

      # True when a scan stopped at a bound (a queue's per-queue cap, a sorted
      # set's page loop, or the shared per-request budget) with elements left
      # unexamined — the hit list may be incomplete. Meaningful only after
      # `each`/`to_a` has driven the scan.
      def truncated? = @truncated

      # Streams matching hits across every selected store. Stops at `limit`.
      # Yields Hashes shaped like sorted_entry payloads with an extra
      # `:kind` discriminator + `:name` (queue name or set name).
      def each(&)
        return enum_for(:each) unless block_given?
        return if @substring.empty?

        @scanned = 0
        @truncated = false
        emitted = 0
        each_hit do |row|
          yield row
          emitted += 1
          break if emitted >= @limit
        end
      end

      def to_a
        each.to_a
      end

      private

      def each_hit(&block)
        @kinds.each do |kind|
          case kind
          when 'queues' then search_queues(&block)
          else search_sorted_set(kind, &block)
          end
        end
      end

      def search_queues
        Queue.all.each do |queue|
          if @scanned >= SCAN_BUDGET
            @truncated = true
            break
          end

          scan_queue_list(queue.name) do |payload|
            next unless payload.include?(@substring)

            yield queue_row(queue.name, JobRecord.new(payload, queue.name))
          end
        end
      end

      # LRANGE-pages one queue LIST, yielding each raw payload to the substring
      # filter. `LLEN` gives the exact size up front (see #queue_scan_stop), so
      # we scan a bounded prefix and never full-walk the LIST from a keystroke.
      def scan_queue_list(queue_name, &)
        key = Keys.queue(queue_name)
        stop_at = queue_scan_stop(Wurk.redis(idempotent: true) { |c| c.call('LLEN', key) })
        start = 0
        while start < stop_at
          slice = Wurk.redis(idempotent: true) do |c|
            c.call('LRANGE', key, start, [start + QUEUE_PAGE, stop_at].min - 1)
          end
          break if slice.empty?

          slice.each(&)
          start += slice.size
        end
        @scanned += start
      end

      # Elements to examine in a queue of `size`: the smaller of the per-queue
      # cap and the request budget still unspent. Flags @truncated when the
      # queue holds more than we'll scan, so the flag is set only for a genuine
      # partial result.
      def queue_scan_stop(size)
        cap = [SCAN_LIMIT_PER_QUEUE, SCAN_BUDGET - @scanned].min
        @truncated = true if size > cap
        [size, cap].min
      end

      # ZSCAN-pages a sorted set, filtering client-side and metering the
      # elements Redis returns against the shared budget so a rare/no-match
      # keystroke can't round-trip an arbitrarily large ZSET. Flags @truncated
      # when the budget stops the scan with entries still unexamined (cursor not
      # yet wrapped back to 0).
      def search_sorted_set(kind, &)
        set = sorted_set_for(kind)
        cursor = '0'
        loop do
          cursor, page = Wurk.redis(idempotent: true) { |c| c.call('ZSCAN', set.name, cursor, 'COUNT', ZSCAN_PAGE) }
          emit_sorted_hits(kind, set, page, &)
          @scanned += page.size / 2
          break if cursor == '0'
          next if @scanned < SCAN_BUDGET

          @truncated = true
          break
        end
      end

      # Yields a sorted_row for each element on this ZSCAN page whose raw JSON
      # contains the literal substring (client-side filter — see the class note).
      def emit_sorted_hits(kind, set, page)
        page.each_slice(2) do |value, score|
          next unless value.include?(@substring)

          yield sorted_row(kind, set.name, SortedEntry.new(set, score.to_f, value))
        end
      end

      def sorted_set_for(kind)
        case kind
        when 'retry'     then RetrySet.new
        when 'scheduled' then ScheduledSet.new
        when 'dead'      then DeadSet.new
        end
      end

      def queue_row(name, record)
        {
          kind: 'queue',
          name: name,
          jid: record.jid,
          klass: record.display_class,
          args: record.display_args,
          queue: record.queue,
          enqueued_at: record.enqueued_at&.to_f,
          created_at: record.created_at&.to_f
        }
      end

      def sorted_row(kind, name, entry)
        {
          kind: kind,
          name: name,
          jid: entry.jid,
          klass: entry.display_class,
          args: entry.display_args,
          queue: entry.queue,
          enqueued_at: entry.enqueued_at&.to_f,
          created_at: entry.created_at&.to_f,
          score: entry.score,
          at: entry.at.to_f,
          error_class: entry['error_class'],
          error_message: entry['error_message'],
          retry_count: entry['retry_count']
        }
      end
    end
  end
end
