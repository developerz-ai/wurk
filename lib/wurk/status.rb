# frozen_string_literal: true

require_relative 'keys'
require_relative 'lua'
require_relative 'pool_checkout'
require_relative 'status/record'
require_relative 'status/progress'

module Wurk
  # Per-job status, progress and result — a Wurk extra, not a Sidekiq surface.
  # Sidekiq loses a job the moment it succeeds: there is no lookup by jid, no
  # progress outside batches and iterables, and no record of what `perform`
  # returned. `Wurk::Status` is that record.
  #
  # Redis schema — one new key, nothing existing touched:
  #
  #   status:<jid>   HASH   state, queue, class, enqueued_at, started_at,
  #                         finished_at, progress, total, message, result,
  #                         error_class, error_message, attempt
  #
  # Every write re-stamps the row's TTL (`status_ttl`, default
  # {Wurk::Keys::STATUS_TTL}), so an abandoned row disappears on its own — no
  # sweeper, no unbounded key growth. A succeeded job's row can be kept longer,
  # or dropped immediately, via `status_retention`.
  #
  # Tracking is opt-in per worker class. A class that doesn't opt in never
  # reaches this module, so an untracked job costs exactly what it costs today.
  #
  # @see Wurk::Status::Progress for the in-job `status.at(...)` handle
  module Status
    # The state machine, in order. `enqueued` and `running` are transient;
    # the rest are terminal for one attempt (`retrying` is terminal for the
    # attempt, not the job — the next attempt writes `running` again).
    STATES = %w[enqueued running complete failed interrupted retrying dead].freeze

    class << self
      def key(jid) = Keys.status(jid)

      # The opt-in gate, in one place: everything that writes a status row asks
      # this first. `track` rides on the job payload (merged in from the
      # class's `sidekiq_options`), so a job enqueued before the option was set
      # keeps running untracked to completion instead of half-tracking.
      def tracked?(job) = job['track'] ? true : false

      # @return [Integer] seconds a status row lives, re-stamped on every write.
      def default_ttl(config = Wurk.configuration) = (config[:status_ttl] || Keys::STATUS_TTL).to_i

      # How long a `complete` row outlives the job that wrote it.
      #
      # @return [Integer, nil] nil (the default) to expire on the same clock as
      #   every other row; 0 to delete the row the moment the job succeeds,
      #   which is what Sidekiq does today — a succeeded job leaves nothing.
      def retention(config = Wurk.configuration) = config[:status_retention]&.to_i

      # Append this job's `enqueued` row onto an already-open pipeline — the
      # client's own queue-write pipeline, never one of ours. Two commands, no
      # round trip of its own, and nothing at all for a job whose class never
      # opted in: {Wurk::Client} does not call this for an untracked payload,
      # so a plain push stays exactly the SADD + LPUSH it has always been.
      #
      # HSET + EXPIRE rather than the status_write script, for two reasons. A
      # NOSCRIPT from an EVALSHA surfaces only when the pipeline finalizes, and
      # Client#push_immediate keeps Lua out of the plain pipeline precisely so
      # a script reload can never replay an already-applied LPUSH into a second
      # copy of the job; both commands here are idempotent, so they are also
      # safe in the batched pipeline, which does replay. And the create gate
      # the script exists for is meaningless on this path: this write IS the
      # create.
      #
      # Only immediate pushes write a row. A scheduled job sits in the ZSET for
      # minutes or days — well past {#default_ttl} — so a row claiming
      # `enqueued` would expire before the job ran, and the state machine has
      # no `scheduled` state to tell the truth with. Its first row is the
      # `running` one the server middleware writes, which re-derives every
      # timestamp from the payload anyway.
      def enqueued(pipe, job, at_millis, ttl: default_ttl)
        jid = job['jid']
        return if jid.nil? || jid.to_s.empty?

        row = key(jid)
        pipe.call('HSET', row, 'state', 'enqueued', 'class', job['class'].to_s,
                  'queue', job['queue'].to_s, 'enqueued_at', (at_millis / 1000.0).to_s)
        pipe.call('EXPIRE', row, ttl)
      end

      # @return [Wurk::Status::Record, nil] nil when no row exists — the jid is
      #   unknown, the class isn't tracked, or the row's TTL has lapsed.
      def get(jid, pool: nil)
        raw = with_pool(pool, idempotent: true) { |conn| conn.call('HGETALL', key(jid)) }
        row = normalize_hgetall(raw)
        return nil if row.empty?

        Record.new(jid.to_s, row)
      end

      # @return [Boolean] true when a row was actually removed.
      def delete(jid, pool: nil) # rubocop:disable Naming/PredicateMethod
        with_pool(pool) { |conn| conn.call('UNLINK', key(jid)) }.to_i.positive?
      end

      # Write fields onto a status row and re-stamp its TTL, in one round trip.
      #
      # `create: false` is the progress path: it updates a live row but will
      # not conjure one that expired or was deleted, which would leave a
      # stateless phantom behind (see lua/status_write.lua).
      #
      # nil values are dropped rather than written as empty strings, so a
      # caller can pass the whole field set every time and let the unset ones
      # fall away.
      #
      # @return [Boolean] true when the row was written.
      def write(jid, ttl: nil, create: true, pool: nil, **fields) # rubocop:disable Naming/PredicateMethod
        validate_state!(fields[:state])
        argv = flatten(fields)
        return false if argv.empty?

        wrote = with_pool(pool) do |conn|
          Lua::Loader.eval_cached(conn, :status_write, keys: [key(jid)],
                                                       argv: [(ttl || default_ttl).to_i, create ? '1' : '0', *argv])
        end
        wrote.to_i == 1
      end

      private

      def validate_state!(state)
        return if state.nil? || STATES.include?(state.to_s)

        raise ArgumentError, "unknown status state: #{state.inspect}"
      end

      def flatten(fields)
        fields.each_with_object([]) do |(name, value), argv|
          next if value.nil?

          argv << name.to_s << value.to_s
        end
      end

      # HGETALL comes back as a Hash under RESP3 and a flat array under RESP2;
      # Wurk supports both protocols, so neither shape may be assumed.
      def normalize_hgetall(raw)
        case raw
        when Hash  then raw
        when Array then raw.each_slice(2).to_h
        else            {}
        end
      end

      def with_pool(pool, idempotent: false, &)
        pool ? PoolCheckout.with(pool, idempotent, &) : Wurk.redis(idempotent:, &)
      end
    end
  end
end
