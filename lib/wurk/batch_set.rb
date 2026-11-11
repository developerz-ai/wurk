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
    TAG_SCAN_LIMIT = 20_000

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

    # The set's size and the #each-ordered page of `count` batches from
    # `offset`, each as its Status#summary: the page's ids in one round trip
    # and every row's hash and set sizes in a second, where #each pays a round
    # trip per batch from the top of the set down. Internal reader for the
    # dashboard.
    #
    # @return [Array(Integer, Array<Hash>)]
    def snapshot(offset, count)
      Wurk.redis do |conn|
        size, bids = page_ids(conn, offset, count)
        [size.to_i, summaries(conn, bids)]
      end
    end

    # #snapshot narrowed to the batches tagged `tag` and still indexed in
    # this set: [how many, the page of summaries]. The tag index is a SET, so
    # ordering it newest-first reads every member's score (one ZMSCORE) —
    # bounded at TAG_SCAN_LIMIT members, past which the rest are not listed.
    # Internal reader for the dashboard.
    #
    # @return [Array(Integer, Array<Hash>)]
    def tagged_snapshot(tag, offset, count)
      bids = scan_tags(tag).first(TAG_SCAN_LIMIT)
      Wurk.redis do |conn|
        ranked = newest_first(bids, bids.empty? ? [] : conn.call('ZMSCORE', @key, *bids))
        [ranked.size, summaries(conn, ranked[offset, count] || [])]
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

    private

    # ZCARD and one newest-first page of ids, in one round trip.
    def page_ids(conn, offset, count)
      conn.pipelined do |pipe|
        pipe.call('ZCARD', @key)
        pipe.call('ZRANGE', @key, offset, offset + count - 1, 'REV')
      end
    end

    # The bids `scores` ranks, in ZRANGE REV order (score, then member,
    # descending); an unscored bid is not in this set.
    def newest_first(bids, scores)
      bids.zip(scores).select(&:last).sort { |(a, sa), (b, sb)| [sb.to_f, b] <=> [sa.to_f, a] }.map(&:first)
    end

    def summaries(conn, bids)
      return [] if bids.empty?

      commands = bids.map { |bid| [['HGETALL', "b-#{bid}"], *Wurk::Batch::Status.summary_commands(bid)] }
      replies = conn.pipelined { |pipe| commands.flatten(1).each { |cmd| pipe.call(*cmd) } }
      bids.zip(replies.each_slice(commands.first.size)).map do |bid, (hash, *sizes)|
        Wurk::Batch::Status.new(bid, data: hash).summary(sizes)
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
