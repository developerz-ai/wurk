# frozen_string_literal: true

require 'securerandom'
require 'zlib'
require 'stringio'
require_relative 'keys'
require_relative 'pool_checkout'

module Wurk
  # Job profiling (Sidekiq 8.0+, OSS). When a job is pushed with a `profile`
  # option, the processor wraps `perform` in a Vernier capture; the resulting
  # Firefox-profiler (gecko) JSON is gzipped and stored so the dashboard can
  # hand it to https://profiler.firefox.com for flame-graph inspection.
  #
  # Redis schema (spec §1.7), wire-compat with Sidekiq's Profiles pane:
  #
  #   profiles            ZSET   member = "<token>-<jid>", score = expiry epoch
  #   <token>-<jid>       HASH   jid, type, token, started_at, elapsed, size,
  #                              sid, data (gzipped gecko JSON)
  #
  # Capture is a no-op unless the `vernier` gem is loaded — profiling is an
  # opt-in, dev/staging tool, so vernier stays an optional dependency.
  module Profiler
    # Stored profiles live this long (score = now + TTL); ProfileSet purges
    # expired members on read.
    TTL = 7 * 24 * 60 * 60 # 7 days

    class << self
      # Server-side hook called from Processor#dispatch. Returns the perform
      # result. Only captures when the job opted in AND vernier is present —
      # otherwise it's a plain `yield`. Crucially there is NO blanket rescue
      # here: the job's own exceptions (a normal failure, or JobRetry::Skip
      # from the interrupt/expiry middleware) must propagate untouched so the
      # retry/skip flow works. Only the storage step is made failure-safe
      # (see #safe_store).
      # No `&block` parameter: every job passes through here, and declaring one
      # would reify the caller's block into a Proc even on the `yield`-straight-
      # through path that opted-out jobs take. The capture path pays for its own
      # block instead.
      def call(job_hash)
        label = job_hash['profile']
        return yield unless label && defined?(::Vernier)

        capture(job_hash, label) { yield } # rubocop:disable Style/ExplicitBlockArgument
      end

      # Persists a profile. Extracted from capture so it is unit-testable
      # without vernier: tests pass a ready gecko JSON blob. The wide keyword
      # list mirrors the HASH fields one-to-one — collapsing them into an
      # options hash would just hide the schema.
      def store(jid:, type:, gecko_json:, started_at:, elapsed_ms:, token: SecureRandom.hex(8),
                sid: Wurk.configuration[:identity], pool: nil)
        key = profile_key(token, jid)
        gz = gzip(gecko_json)
        with_pool(pool) do |conn|
          conn.pipelined do |pipe|
            pipe.call('HSET', key, 'jid', jid, 'type', type, 'token', token,
                      'started_at', started_at.to_i, 'elapsed', elapsed_ms.to_i,
                      'size', gz.bytesize, 'sid', sid.to_s, 'data', gz)
            pipe.call('EXPIRE', key, TTL)
            pipe.call('ZADD', Keys::PROFILES, (now + TTL).to_i, key)
          end
        end
        key
      end

      def profile_key(token, jid)
        "#{token}-#{jid}"
      end

      def gzip(str)
        io = StringIO.new(+'', 'wb')
        gz = Zlib::GzipWriter.new(io)
        gz.write(str)
        gz.close
        io.string
      end

      def gunzip(bytes)
        Zlib::GzipReader.new(StringIO.new(bytes)).read
      end

      private

      # Wrap the block in a Vernier capture, write the gecko JSON to a tempfile
      # (Vernier serializes on block exit), then store it. Only reached when
      # vernier is loaded.
      def capture(job_hash, label)
        retval = nil
        started = now
        elapsed_ms = nil
        json = profile_to_json do
          t0 = monotonic_ms
          retval = yield
          elapsed_ms = monotonic_ms - t0
        end
        safe_store(job_hash, label, json, started, elapsed_ms)
        retval
      end

      # The job already ran successfully by the time we get here; a Redis hiccup
      # persisting the profile must not turn a green job red. Job exceptions
      # never reach this method — they propagate out of `capture`'s yield.
      def safe_store(job_hash, label, json, started, elapsed_ms)
        store(jid: job_hash['jid'], type: label.to_s, gecko_json: json,
              started_at: started, elapsed_ms: elapsed_ms)
      rescue StandardError => e
        Wurk.configuration.handle_exception(e, context: 'Wurk::Profiler')
      end

      # `tempfile` (and the `tmpdir` it drags in) is ~19ms of `require "wurk"`,
      # spent only by an install that has vernier loaded AND profiling switched
      # on for a job. Everyone else was paying it at boot.
      def profile_to_json(&)
        require 'tempfile'

        Tempfile.create(['wurk-profile', '.json']) do |file|
          ::Vernier.profile(out: file.path, &)
          File.read(file.path)
        end
      end

      def with_pool(pool, idempotent: false, &)
        pool ? PoolCheckout.with(pool, idempotent, &) : Wurk.redis(idempotent:, &)
      end

      def now
        ::Time.now.to_f
      end

      def monotonic_ms
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC, :float_millisecond)
      end
    end
  end
end
