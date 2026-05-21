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
    # ZSET stores use `ZSCAN MATCH *needle*` (the substring is literal,
    # wrapped in glob stars — Redis matches the raw JSON payload). The queue
    # LIST falls back to a paged LRANGE filter since LIST has no SCAN.
    #
    # Result shape mirrors `Wurk::Api::Serializers#sorted_entry` so the SPA
    # renders search hits with the same component as a sorted-set row.
    class Search
      DEFAULT_LIMIT = 100
      MAX_LIMIT = 500
      KINDS = %w[queues retry scheduled dead].freeze
      QUEUE_PAGE = 50
      ZSCAN_PAGE = 200

      attr_reader :substring, :kinds, :limit

      def initialize(substring, kinds: KINDS, limit: DEFAULT_LIMIT)
        @substring = substring.to_s
        @kinds = (Array(kinds).map(&:to_s) & KINDS)
        @kinds = KINDS.dup if @kinds.empty?
        @limit = limit.to_i.clamp(1, MAX_LIMIT)
      end

      # Streams matching hits across every selected store. Stops at `limit`.
      # Yields Hashes shaped like sorted_entry payloads with an extra
      # `:kind` discriminator + `:name` (queue name or set name).
      def each(&)
        return enum_for(:each) unless block_given?
        return if @substring.empty?

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
          paged_lrange(queue.name) do |payload|
            next unless payload.include?(@substring)

            record = JobRecord.new(payload, queue.name)
            yield queue_row(queue.name, record)
          end
        end
      end

      def paged_lrange(queue_name, &block)
        key = Keys.queue(queue_name)
        page = 0
        loop do
          start = page * QUEUE_PAGE
          stop = start + QUEUE_PAGE - 1
          slice = Wurk.redis { |c| c.call('LRANGE', key, start, stop) }
          slice.each(&block)
          break if slice.size < QUEUE_PAGE

          page += 1
        end
      end

      def search_sorted_set(kind, &)
        set = sorted_set_for(kind)
        set.scan(@substring, ZSCAN_PAGE) do |value, score|
          yield sorted_row(kind, set.name, SortedEntry.new(set, score, value))
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
