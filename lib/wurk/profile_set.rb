# frozen_string_literal: true

require_relative 'keys'
require_relative 'profiler'

module Wurk
  # Read-only view over stored job profiles (Sidekiq 8.0+ data API, spec §19.8).
  # `ProfileSet` enumerates the `profiles` ZSET, purging expired members first;
  # `ProfileRecord` wraps one `<token>-<jid>` HASH.
  class ProfileSet
    include Enumerable

    # Snapshot the (non-expired) member keys at construction. ZREMRANGEBYSCORE
    # drops members whose expiry score has passed before we read the rest.
    def initialize
      @keys = Wurk.redis do |conn|
        conn.call('ZREMRANGEBYSCORE', Keys::PROFILES, '-inf', "(#{::Time.now.to_i}")
        conn.call('ZRANGE', Keys::PROFILES, 0, -1)
      end
    end

    def size = @keys.size

    def each
      return enum_for(:each) unless block_given?

      Wurk.redis do |conn|
        @keys.each do |key|
          raw = conn.call('HGETALL', key)
          hash = raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
          yield ProfileRecord.new(hash) unless hash.empty?
        end
      end
    end
  end

  # One profile record: the metadata fields of a `<token>-<jid>` HASH plus
  # lazy access to the gzipped gecko blob. Spec §19.8.
  class ProfileRecord
    attr_reader :jid, :type, :token, :size, :elapsed

    def initialize(hash)
      @hash = hash
      @jid = hash['jid']
      @type = hash['type']
      @token = hash['token']
      @size = hash['size'].to_i
      @elapsed = hash['elapsed'].to_i
    end

    def started_at
      ts = @hash['started_at']
      ::Time.at(ts.to_i) unless ts.nil? || ts.empty?
    end

    def key = Wurk::Profiler.profile_key(@token, @jid)

    # The stored blob is gzipped gecko JSON. `data` returns the raw (gzipped)
    # bytes — the web layer streams them straight to the browser with a gzip
    # Content-Encoding. Returns nil if the HASH expired between list and read.
    def data
      Wurk.redis { |conn| conn.call('HGET', key, 'data') }
    end
  end
end
