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
  # Every write re-stamps {Wurk::Keys::STATUS_TTL}, so an abandoned row
  # disappears on its own — no sweeper, no unbounded key growth.
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
      def write(jid, ttl: Keys::STATUS_TTL, create: true, pool: nil, **fields) # rubocop:disable Naming/PredicateMethod
        validate_state!(fields[:state])
        argv = flatten(fields)
        return false if argv.empty?

        wrote = with_pool(pool) do |conn|
          Lua::Loader.eval_cached(conn, :status_write, keys: [key(jid)],
                                                       argv: [ttl.to_i, create ? '1' : '0', *argv])
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
