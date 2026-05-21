# frozen_string_literal: true

require_relative 'batch'

module Wurk
  # Discovery API over the global `batches` sorted set. `size`, `each` (yields
  # Status), `scan_tags(tag)` for tag-indexed lookup.
  #
  # Spec: docs/target/sidekiq-pro.md §2.7.
  class BatchSet
    include Enumerable

    PAGE_SIZE = 100

    def initialize(key: 'batches')
      @key = key
    end

    def size
      Wurk.redis { |conn| conn.call('ZCARD', @key) }.to_i
    end

    # Newest-first iteration of every batch indexed in the set. Yields
    # `Wurk::Batch::Status` instances — they HGETALL on construction so
    # the caller pays one Redis round-trip per batch.
    def each
      return enum_for(:each) unless block_given?

      page = 0
      loop do
        start = page * PAGE_SIZE
        stop  = start + PAGE_SIZE - 1
        bids  = Wurk.redis { |conn| conn.call('ZRANGE', @key, start, stop, 'REV') }
        bids.each { |bid| yield Wurk::Batch::Status.new(bid) }
        break if bids.size < PAGE_SIZE

        page += 1
      end
    end

    # Yields each BID indexed under the given tag (set at `tags:<tag>`).
    # No JSON parsing; cheap iteration. Caller wraps in `Status.new(bid)`
    # if it needs full state.
    def scan_tags(tag, &block)
      return enum_for(:scan_tags, tag) unless block_given?

      cursor = '0'
      Wurk.redis do |conn|
        loop do
          cursor, members = conn.call('SSCAN', "tags:#{tag}", cursor, 'COUNT', PAGE_SIZE)
          members.each(&block)
          break if cursor == '0'
        end
      end
    end
  end

  class Batch
    # Discovery view over batches that triggered `:death`. Iterates Status
    # instances newest-first.
    class DeadSet < ::Wurk::BatchSet
      def initialize
        super(key: 'dead-batches')
      end
    end
  end
end
