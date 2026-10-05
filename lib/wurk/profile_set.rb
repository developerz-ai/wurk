# frozen_string_literal: true

require_relative 'keys'
require_relative 'profiler'

module Wurk
  # Read-only view over stored job profiles (Sidekiq 8.0+ data API, spec §19.8).
  # `ProfileSet` enumerates the `profiles` ZSET, purging expired members first;
  # `ProfileRecord` wraps one `<token>-<jid>` HASH.
  class ProfileSet
    include Enumerable

    # Snapshot the (non-expired) member keys at construction, newest first.
    # ZREMRANGEBYSCORE drops members whose expiry score has passed.
    def initialize
      @keys = Wurk.redis do |conn|
        conn.call('ZREMRANGEBYSCORE', Keys::PROFILES, '-inf', ::Time.now.to_f.to_s)
        conn.call('ZRANGE', Keys::PROFILES, '+inf', 0, 'BYSCORE', 'REV')
      end
    end

    def size = @keys.size

    # HMGET of the metadata fields only, pipelined into one round-trip:
    # HGETALL would also pull each profile's `data` field — the multi-MB
    # gzipped blob — through Redis for every list render. Upstream's order,
    # which ProfileRecord.new reads positionally.
    METADATA_FIELDS = %w[started_at jid type token size elapsed].freeze

    def each
      return enum_for(:each) unless block_given?

      rows = Wurk.redis do |conn|
        conn.pipelined do |pipe|
          @keys.each { |key| pipe.call('HMGET', key, *METADATA_FIELDS) }
        end
      end
      rows.each { |values| yield ProfileRecord.new(values) unless values.nil? || values[1].nil? }
    end
  end

  # One profile record: the metadata fields of a `<token>-<jid>` HASH plus
  # lazy access to the gzipped gecko blob. Spec §19.8; `elapsed` is Float
  # seconds and `started_at` a Time, as upstream.
  class ProfileRecord
    attr_reader :started_at, :jid, :type, :token, :size, :elapsed

    # Fetch the stored gzipped blob for a profile storage key ("<token>-<jid>")
    # straight from Redis, without materializing the whole record — the Profiles
    # data endpoint streams it to the browser as-is. nil if the HASH is gone.
    # Owns the `data` HASH-field name so web callers don't hardcode the schema.
    def self.data_for(key)
      Wurk.redis { |conn| conn.call('HGET', key, 'data') }
    end

    # `arr` is the HMGET of ProfileSet::METADATA_FIELDS, in that order.
    def initialize(arr)
      @started_at = ::Time.at(Integer(arr[0]))
      @jid = arr[1]
      @type = arr[2]
      @token = arr[3]
      @size = Integer(arr[4])
      @elapsed = Float(arr[5])
    end

    def key = Wurk::Profiler.profile_key(@token, @jid)

    # The stored blob is gzipped gecko JSON. `data` returns the raw (gzipped)
    # bytes — the web layer streams them straight to the browser with a gzip
    # Content-Encoding. Returns nil if the HASH expired between list and read.
    def data
      self.class.data_for(key)
    end
  end
end
