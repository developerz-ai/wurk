# frozen_string_literal: true

require_relative 'flow'

module Wurk
  # Discovery over the `flows` sorted set: `size`, and `each` newest-first
  # yielding {Wurk::Flow::Status}. The counterpart of {Wurk::BatchSet}, and a
  # separate class rather than a `key:` on that one because the two yield
  # different objects — a set that returns the wrong kind of status to save a
  # constructor is a listing that renders nothing.
  #
  # A flow is discoverable only through this index. Nothing scans `flow:*`:
  # KEYS is refused outright and a SCAN over a production keyspace to build a
  # page of 25 is the pathology the index exists to avoid. The set is trimmed
  # on the same two-axis bound as `batches` (see `Batch.trim_bounds`), so it
  # cannot outgrow what a dashboard can walk.
  class FlowSet
    include Enumerable

    PAGE_SIZE = 100

    def initialize(key: Wurk::Keys::FLOWS_SET)
      @key = key
    end

    def size
      Wurk.redis { |conn| conn.call('ZCARD', @key) }.to_i
    end

    # Newest first, a page of ids per round trip. Each yielded status reads its
    # own header — one round trip per flow, like {Wurk::BatchSet} — and reads
    # no node records unless the caller asks for them.
    #
    # A fid the index still holds whose record has expired yields a status that
    # answers `exists? == false`, rather than being skipped: the caller
    # rendering the page is the one that knows whether a tombstone row is worth
    # showing, and silently dropping members would make a page shorter than the
    # `count` it asked for with no way to tell why.
    def each
      return enum_for(:each) unless block_given?

      page = 0
      loop do
        start = page * PAGE_SIZE
        fids  = Wurk.redis { |conn| conn.call('ZRANGE', @key, start, start + PAGE_SIZE - 1, 'REV') }
        fids.each { |fid| yield Wurk::Flow::Status.new(fid) }
        break if fids.size < PAGE_SIZE

        page += 1
      end
    end

    # The set's size and the #each-ordered page of `count` flows from
    # `offset`: the page's ids in one round trip and every header in a second,
    # where #each pays a round trip per flow from the top of the set down.
    # Internal reader for the dashboard.
    #
    # @return [Array(Integer, Array<Wurk::Flow::Status>)]
    def snapshot(offset, count)
      Wurk.redis do |conn|
        size, fids = page_ids(conn, offset, count)
        headers = fids.empty? ? [] : conn.pipelined { |pipe| fids.each { |fid| pipe.call('HGETALL', Keys.flow(fid)) } }
        [size.to_i, fids.zip(headers).map { |fid, header| Wurk::Flow::Status.new(fid, header: header) }]
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
  end
end
