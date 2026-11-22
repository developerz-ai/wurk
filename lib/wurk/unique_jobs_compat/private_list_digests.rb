# frozen_string_literal: true

require 'json'
require_relative '../keys'

module Wurk
  module UniqueJobsCompat
    # One read of every private list: the lock digests of the jobs in them.
    #
    # Any Redis error propagates, so a caller deciding what to delete deletes
    # nothing. A list longer than a page is read in overlapping pages, because
    # an ACK removing an entry shifts the rest toward the head: the overlap
    # proves no entry slid past the read position, and ListMoved says it did.
    class PrivateListDigests
      class ListMoved < ::StandardError; end

      Result = Struct.new(:digests, :unreadable)

      MATCH = "#{Keys::QUEUE_PREFIX}*|*".freeze
      SCAN_COUNT = 1000
      PAGE = 1000
      OVERLAP = 100
      PIPELINE = 100
      RUN_SUFFIX = ':RUN'
      DIGEST_FIELDS = %w[lock_digest unique_digest].freeze

      def initialize(page: PAGE, overlap: OVERLAP)
        @page = page
        @overlap = overlap
        @result = Result.new(::Set.new, 0)
      end

      def call
        private_lists.each_slice(PIPELINE) do |lists|
          first_pages = Wurk.redis do |conn|
            conn.pipelined { |pipe| lists.each { |list| pipe.call('LRANGE', list, 0, @page - 1) } }
          end
          lists.zip(first_pages) { |list, page| read_list(list, page) }
        end
        @result
      end

      private

      def read_list(list, first_page)
        collect(first_page)
        previous = first_page
        start = @page - @overlap
        while previous.size == @page
          page = read_page(list, start)
          unless page.first(@overlap).intersect?(previous.last(@overlap))
            raise ListMoved,
                  "#{list} moved past the read position"
          end

          collect(page)
          previous = page
          start += @page - @overlap
        end
      end

      def read_page(list, start)
        Wurk.redis { |conn| conn.call('LRANGE', list, start, start + @page - 1) }
      end

      def collect(payloads)
        payloads.each { |payload| collect_payload(payload) }
      end

      def collect_payload(payload)
        job = parse(payload)
        return collect_unreadable(payload) unless job.is_a?(::Hash)

        DIGEST_FIELDS.each { |field| add(job[field]) if job[field].is_a?(::String) }
      end

      # No way to tell which lock it holds, so every quoted string in it counts.
      def collect_unreadable(payload)
        @result.unreadable += 1
        payload.b.split('"').each { |token| add(token) }
      end

      def add(digest)
        @result.digests << digest.delete_suffix(RUN_SUFFIX)
      end

      def parse(payload)
        Wurk.load_json(payload)
      rescue ::JSON::ParserError, ::EncodingError
        nil
      end

      def private_lists
        public_queues = Wurk.redis { |conn| conn.call('SMEMBERS', Keys::QUEUES_SET) }.to_set
        scan_lists.select { |key| private_list?(key, public_queues) }
      end

      # Parsed by each reading on its own: a key that reads as both is one the
      # fetcher refuses to reclaim, and the job in it is real.
      def private_list?(key, public_queues)
        return false unless key.valid_encoding?
        return false if public_queues.include?(key.delete_prefix(Keys::QUEUE_PREFIX))

        !(Fetcher::PrivateListKey.parse_pro(key) || Fetcher::PrivateListKey.parse_wurk(key)).nil?
      end

      def scan_lists
        cursor = '0'
        keys = []
        loop do
          cursor, batch = Wurk.redis do |conn|
            conn.call('SCAN', cursor, 'MATCH', MATCH, 'COUNT', SCAN_COUNT, 'TYPE', 'list')
          end
          keys.concat(batch)
          break if cursor == '0'
        end
        keys.uniq
      end
    end
  end
end
