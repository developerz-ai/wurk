# frozen_string_literal: true

require_relative '../batch'
require_relative '../keys'

module Wurk
  module Preflight
    # One SCAN pass over the keyspace, sorted into the families the checks ask
    # about. A pass costs one round trip per COUNT keys and pauses between pages,
    # so it never holds Redis, and stops at `limit` keys with `truncated` set:
    # counts are then lower bounds and the report says so.
    class Keyspace
      PAGE = 1000
      PROGRESS_EVERY = 100_000
      # Lists and batches kept for a closer look. Far above any real fleet's
      # private lists; a keyspace with more has a bigger problem than this report.
      RETAINED = 10_000

      SHA1_DIGEST = /\A[0-9a-f]{40}\z/
      SHA256_DIGEST = /\A[0-9a-f]{64}\z/
      GEM_LOCK = /\Auniquejobs:[0-9a-f]{32}\z/
      NAMESPACED_QUEUE = /\A[^:|]+:queue:[^|]+\z/
      BATCH_SUFFIX = /-(?:#{Wurk::Batch::KEY_SUFFIXES.join('|')}|failinfo)\z/

      COUNTED = %w[private_lists batches unique_sha1 unique_sha256 unique_other gem_locks gem_keys
                   cron_entries namespaced_queues limiters].freeze

      attr_reader :scanned, :counts, :private_lists, :batches

      def initialize(reader, limit:, pause: 0.005, progress: nil)
        @reader = reader
        @limit = limit
        @pause = pause
        @progress = progress
        @scanned = 0
        @truncated = false
        @counts = COUNTED.to_h { |name| [name, 0] }
        @private_lists = []
        @batches = []
      end

      def truncated? = @truncated

      def walk
        cursor = '0'
        loop do
          cursor, keys = @reader.call('SCAN', cursor, 'COUNT', PAGE)
          keys.each { |key| classify(key) }
          report_progress(keys.size)
          break if cursor == '0'
          break @truncated = true if @scanned >= @limit

          sleep(@pause) if @pause.positive?
        end
        self
      end

      def to_h
        { 'keys_scanned' => @scanned, 'truncated' => @truncated }.merge(@counts)
      end

      private

      def report_progress(page)
        before = @scanned
        @scanned += page
        return unless @progress && before / PROGRESS_EVERY != @scanned / PROGRESS_EVERY

        @progress.call("scanned #{@scanned} keys")
      end

      def classify(raw)
        key = raw.valid_encoding? ? raw : raw.b
        case key
        when /\Aqueue:.*\|/m then retain(@private_lists, 'private_lists', key)
        when /\Ab-/ then classify_batch(key)
        when /\Aunique:/ then classify_unique(key)
        when /\Auniquejobs:/ then classify_gem_lock(key)
        when /\Acron_job:/ then @counts['cron_entries'] += 1 unless key.end_with?(':enqueued', ':jid_history')
        when /\Almtr/ then @counts['limiters'] += 1
        when NAMESPACED_QUEUE then @counts['namespaced_queues'] += 1
        end
      end

      def retain(list, count, key)
        @counts[count] += 1
        list << key if list.size < RETAINED
      end

      def classify_batch(key)
        retain(@batches, 'batches', key) unless key.match?(BATCH_SUFFIX)
      end

      def classify_unique(key)
        digest = key.delete_prefix('unique:')
        family = if digest.match?(SHA1_DIGEST) then 'unique_sha1'
                 elsif digest.match?(SHA256_DIGEST) then 'unique_sha256'
                 else 'unique_other'
                 end
        @counts[family] += 1
      end

      def classify_gem_lock(key)
        @counts['gem_keys'] += 1
        @counts['gem_locks'] += 1 if key.match?(GEM_LOCK)
      end
    end
  end
end
