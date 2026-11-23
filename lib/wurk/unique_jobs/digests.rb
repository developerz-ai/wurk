# frozen_string_literal: true

module Wurk
  module UniqueJobs
    # Deletes digests and every key the gem keeps beside them, 500 per pipeline.
    class BatchDelete
      BATCH_SIZE = 500
      SUFFIXES = %w[QUEUED PRIMED LOCKED INFO].freeze

      def self.call(digests, conn = nil) = new(digests, conn).call

      def initialize(digests, conn)
        @digests = Array(digests).compact
        @conn = conn
      end

      def call
        return 0 if @digests.empty?
        return delete(@conn) if @conn

        UniqueJobs.redis { |conn| delete(conn) }
      end

      private

      def delete(conn)
        @digests.each_slice(BATCH_SIZE) do |chunk|
          conn.pipelined do |pipe|
            chunk.each do |digest|
              pipe.call('UNLINK', *keys_for(digest))
              pipe.call('ZREM', DIGESTS, digest)
              pipe.call('ZREM', EXPIRING_DIGESTS, digest)
            end
          end
        end
        @digests.size
      end

      def keys_for(digest)
        [digest, "#{digest}#{RUN_SUFFIX}"].flat_map { |key| [key, *SUFFIXES.map { |suffix| "#{key}:#{suffix}" }] }
      end
    end

    # A score-indexed set, read with ZSCAN so a large one never blocks Redis.
    class ScannedSet
      SCAN_PATTERN = '*'
      DEFAULT_COUNT = 1_000

      attr_reader :key

      def initialize(key)
        @key = key
      end

      def count = UniqueJobs.redis { |conn| conn.call('ZCARD', key) }

      # Every member matching `pattern` with its score; `count` is the ZSCAN hint.
      def entries(pattern: SCAN_PATTERN, count: DEFAULT_COUNT)
        result = {}
        cursor = '0'
        loop do
          cursor, batch = UniqueJobs.redis { |conn| conn.call('ZSCAN', key, cursor, 'MATCH', pattern, 'COUNT', count) }
          batch.each_slice(2) { |member, score| result[member] = score.to_f }
          break if cursor == '0'
        end
        result
      end

      def byscore(min, max, offset: nil, count: nil)
        limit = offset && count ? ['LIMIT', offset, count] : []
        UniqueJobs.redis { |conn| conn.call('ZRANGE', key, min, max, 'BYSCORE', *limit) }
      end

      def score(member) = UniqueJobs.redis { |conn| conn.call('ZSCORE', key, member) }&.to_f

      # [size, next cursor, page] for the dashboard's paging.
      def page(cursor: 0, pattern: SCAN_PATTERN, page_size: 100)
        size, (next_cursor, members) = UniqueJobs.redis do |conn|
          conn.pipelined do |pipe|
            pipe.call('ZCARD', key)
            pipe.call('ZSCAN', key, cursor, 'MATCH', pattern, 'COUNT', page_size)
          end
        end
        [size.to_i, next_cursor.to_i, members.each_slice(2).map { |member, score| page_entry(member, score) }]
      end

      private

      def page_entry(member, score) = [member, score.to_f]
    end

    # `uniquejobs:digests`: every digest locked by a lock type that unlocks.
    class Digests < ScannedSet
      def initialize(digests_key = DIGESTS)
        super
      end

      def add(digest) = UniqueJobs.redis { |conn| conn.call('ZADD', key, UniqueJobs.now_f, digest) }

      def delete_by_pattern(pattern, count: DEFAULT_COUNT)
        BatchDelete.call(entries(pattern: pattern, count: count).keys)
      end

      # The digest's queue-time and run-time keys (`<digest>:RUN:*`), and its entry here.
      def delete_by_digest(digest, queuetime: true, runtime: true)
        keys = digest_keys(queuetime ? digest : nil) + digest_keys(runtime ? "#{digest}#{RUN_SUFFIX}" : nil) + [key]
        UniqueJobs.redis { |conn| Script.call(:unique_jobs_delete_by_digest, conn, keys: keys) }
      end

      private

      def digest_keys(digest)
        return ['', '', '', ''] unless digest

        [digest, "#{digest}:QUEUED", "#{digest}:PRIMED", "#{digest}:LOCKED"]
      end

      def page_entry(member, score) = Lock.new(member, time: score)
    end

    # `uniquejobs:expiring_digests`: the `until_expired` digests, scored by expiry.
    class ExpiringDigests < Digests
      def initialize
        super(EXPIRING_DIGESTS)
      end
    end

    # `uniquejobs:changelog`: what the lock scripts did, newest last, capped at
    # `max_history` entries (0 writes none).
    class Changelog < ScannedSet
      def initialize
        super(CHANGELOGS)
      end

      def add(message:, job_id:, script:, digest:)
        entry = Wurk.dump_json(digest: digest, job_id: job_id, script: script, message: message,
                               time: UniqueJobs.now_f)
        UniqueJobs.redis { |conn| conn.call('ZADD', key, UniqueJobs.now_f, entry) }
      end

      def clear = UniqueJobs.redis { |conn| conn.call('DEL', key) }

      def entries(pattern: SCAN_PATTERN, count: DEFAULT_COUNT)
        super.keys.map { |entry| Wurk.load_json(entry) }
      end

      private

      def page_entry(member, _score) = Wurk.load_json(member)
    end

    # Releases a job's lock from its payload alone, recomputing the digest.
    module Unlockable
      module_function

      def unlock(item) = locksmith(item).unlock
      def unlock!(item) = locksmith(item).unlock!
      def delete(item) = locksmith(item).delete
      def delete!(item) = locksmith(item).delete!

      def locksmith(item) = Locksmith.new(Job.add_digest(item))
    end
  end
end
