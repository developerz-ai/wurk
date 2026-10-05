# frozen_string_literal: true

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
  # Redis schema (spec §1.7, §19.8), field-for-field Sidekiq 8.1's Profiler:
  #
  #   profiles            ZSET   member = "<token>-<jid>", score = expiry epoch (float)
  #   <token>-<jid>       HASH   started_at (int epoch), token (the job's
  #                              `profile` value), type (wrapped || class), jid,
  #                              elapsed (float seconds), size (bytes of data),
  #                              data (gzipped gecko JSON)
  #
  # `sid` is not written here: it is the profile-store id the Web UI caches
  # after its first upload, and a value in it makes the UI skip the upload.
  #
  # Capture is a no-op unless the `vernier` gem is loaded — profiling is an
  # opt-in, dev/staging tool, so vernier stays an optional dependency.
  module Profiler
    EXPIRY = 86_400
    DEFAULT_OPTIONS = { mode: :wall }.freeze

    class << self
      # Server-side hook called from Processor#dispatch. Returns the perform
      # result. Only captures when the job opted in AND vernier is present —
      # otherwise it's a plain `yield`. There is NO blanket rescue: the job's
      # own exceptions (a normal failure, or JobRetry::Skip) must propagate
      # untouched, and a failed job stores no profile (upstream behaviour).
      # Only the storage step is made failure-safe (see #safe_store).
      # No `&block` parameter: every job passes through here, and declaring one
      # would reify the caller's block into a Proc even on the `yield`-straight-
      # through path that opted-out jobs take.
      def call(job_hash)
        return yield unless job_hash['profile'] && defined?(::Vernier)

        capture(job_hash) { yield } # rubocop:disable Style/ExplicitBlockArgument
      end

      # Persists a profile. Extracted from capture so it is unit-testable
      # without vernier: tests pass a ready gecko JSON blob.
      def store(jid:, type:, token:, gecko_json:, started_at:, elapsed:, pool: nil)
        key = profile_key(token, jid)
        gz = gzip(gecko_json)
        with_pool(pool) do |conn|
          conn.multi do |tx|
            tx.call('ZADD', Keys::PROFILES, ::Time.now.to_f + EXPIRY, key)
            tx.call('HSET', key, 'started_at', started_at.to_i, 'token', token, 'type', type, 'jid', jid,
                    'elapsed', elapsed.to_f, 'data', gz, 'size', gz.bytesize)
            tx.call('EXPIRE', key, EXPIRY)
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
      # vernier is loaded. `elapsed` spans the whole capture, as upstream's
      # does.
      def capture(job_hash)
        retval = nil
        started = ::Time.now
        t0 = monotonic
        json = profile_to_json(profiler_options(job_hash)) { retval = yield }
        safe_store(job_hash, json, started, monotonic - t0)
        retval
      end

      # The job already ran successfully by the time we get here; a Redis hiccup
      # persisting the profile must not turn a green job red. Job exceptions
      # never reach this method — they propagate out of `capture`'s yield.
      def safe_store(job_hash, json, started, elapsed)
        store(jid: job_hash['jid'], token: job_hash['profile'].to_s,
              type: job_hash['wrapped'] || job_hash['class'], gecko_json: json,
              started_at: started, elapsed: elapsed)
      rescue StandardError => e
        Wurk.configuration.handle_exception(e, context: 'Wurk::Profiler')
      end

      # The job's `profiler_options` hash is passed to Vernier.profile, over a
      # `mode: :wall` default (upstream's DEFAULT_OPTIONS).
      def profiler_options(job_hash)
        opts = (job_hash['profiler_options'] || {}).transform_keys(&:to_sym)
        opts[:mode] = opts[:mode].to_sym if opts[:mode]
        DEFAULT_OPTIONS.merge(opts)
      end

      # `tempfile` (and the `tmpdir` it drags in) is ~19ms of `require "wurk"`,
      # spent only by an install that has vernier loaded AND profiling switched
      # on for a job. Everyone else was paying it at boot.
      def profile_to_json(options, &)
        require 'tempfile'

        Tempfile.create(['wurk-profile', '.json']) do |file|
          ::Vernier.profile(**options, out: file.path, &)
          File.read(file.path)
        end
      end

      def with_pool(pool, idempotent: false, &)
        pool ? PoolCheckout.with(pool, idempotent, &) : Wurk.redis(idempotent:, &)
      end

      def monotonic
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end
    end
  end
end
