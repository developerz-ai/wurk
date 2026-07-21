# frozen_string_literal: true

require_relative 'job_record'

module Wurk
  # One entry inside a sorted-set view (Retry/Scheduled/Dead). Carries the
  # member's `score` alongside the JobRecord so callers can re-target the
  # exact (score, value) pair when mutating Redis — sorted-set membership is
  # by value, but ZREM-by-value is faster than ZRANGEBYSCORE+filter.
  #
  # The `id` field ("<score>|<jid>") is the Sidekiq wire-compat identifier
  # used by dashboards and third-party tooling. Don't reformat it.
  #
  # Spec: docs/target/sidekiq-free.md §19.4.
  class SortedEntry < JobRecord
    attr_reader :score, :parent

    # @param parent [JobSet, nil] the owning set; nil when constructed bare.
    # @param score [Numeric] ZSET score (Float seconds since epoch).
    # @param item [String, Hash] raw JSON or parsed payload.
    def initialize(parent, score, item)
      super(item)
      @score = score.to_f
      @parent = parent
    end

    # JobRecord resolves the queue eagerly and only from a pre-parsed Hash;
    # a sorted-set entry is almost always built from the raw JSON string, so
    # read it off the payload instead. Lazy on purpose — a scan over a large
    # set must not pay JSON cost for entries nobody inspects.
    def queue = @queue ||= item['queue']

    def id = "#{score}|#{jid}"

    def at = ::Time.at(score).utc

    # Removes this entry from the parent set. Prefers exact-value match
    # (idempotent across duplicates with the same jid), falls back to
    # (score, jid) when constructed without a cached `value`.
    def delete
      if @value
        @parent.delete_by_value(@parent.name, @value)
      else
        @parent.delete_by_jid(@score, jid)
      end
    end

    # ZINCRBY to shift the score; positive deltas reschedule into the future.
    # Sidekiq passes the absolute target time; we compute the delta here so
    # the call survives clock skew between caller and Redis.
    def reschedule(at)
      Wurk.redis { |conn| conn.call('ZINCRBY', @parent.name, at.to_f - @score, value) }
    end

    # Removes this entry and re-enqueues it via the client with the payload
    # untouched. Backs the scheduled/dead "add to queue" actions — Sidekiq's
    # add_to_queue does not touch `retry_count`.
    def add_to_queue
      remove_job do |message|
        Client.new.push(message)
      end
    end

    # Same flow but decrements `retry_count` first: the count was already
    # incremented when the job entered the retry set, and the next failure
    # bumps it again — without the decrement a manual "Retry now" would
    # consume an attempt. Wire-compat with Sidekiq's SortedEntry#retry.
    def retry
      remove_job do |message|
        message['retry_count'] = message['retry_count'].to_i - 1 if message['retry_count']
        Client.new.push(message)
      end
    end

    # Removes this entry from its parent set and writes it to the dead set.
    # Death handlers fire with the synthesized "Job killed by API" exception
    # (Sidekiq's default) so error trackers and the batch death path observe
    # API/UI kills.
    def kill
      remove_job do |message|
        DeadSet.new.kill(Wurk.dump_json(message))
      end
    end

    def error? = !item['error_class'].nil?

    private

    # Pulls the message out of Redis, yields it for the caller's re-enqueue
    # work, and returns the parsed hash. Done with the cached value when
    # available so LREM-like ZREM matches the exact bytes.
    # Returns nil without yielding when the parent removal fails — prevents
    # duplicate side effects (e.g. retry pushing twice) if another caller
    # already removed the entry.
    def remove_job
      message = item.dup
      return nil unless @parent.remove_job(self)

      yield message
      message
    end
  end
end
