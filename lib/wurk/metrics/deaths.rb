# frozen_string_literal: true

require 'json'
require_relative '../keys'
require_relative '../lua'

module Wurk
  module Metrics
    # Cluster-wide, monotonic count of jobs moved to the dead set, per queue and
    # class, in `stat:deaths` (Keys::STAT_DEATHS). The dead set is capped at
    # `dead_max_jobs`: once full, every kill trims the oldest entry, so its size
    # stops moving and cannot say how many jobs died. This count can.
    #
    # Labels come from the payload's `queue` and its `wrapped` class (an
    # ActiveJob's own class) or `class`, never the jid or args. A field the
    # payload cannot supply is `unknown`. Distinct pairs past MAX_SERIES fold
    # into OVERFLOW (`lua/count_death.lua`).
    #
    # Best effort: a count that fails after the kill is lost, and only Wurk
    # writes it (a stock Sidekiq process in a mixed fleet does not). #record
    # reports the failure; the schedule-promote script cannot, and drops it.
    #
    # Fields are encoded `script_safe`, escaping `/` as Redis's cjson does, so a
    # pair the schedule-promote script counts lands on the same field.
    module Deaths
      MAX_SERIES = 500
      UNKNOWN = 'unknown'
      OTHER = 'other'
      OVERFLOW = ::JSON.generate([OTHER, OTHER]).freeze
      # Name, help and type of the `/metrics` family (Metrics::Prometheus), whose
      # samples are #samples. Read from shared Redis, so every scrape target
      # reports the same value: aggregate with `max`.
      FAMILY = ['wurk_jobs_dead_total', 'Jobs moved to the dead set, by queue and class (stat:deaths).',
                'counter'].freeze

      class << self
        # Counts one death. Runs once, never replayed (`eval_once`), so a dropped
        # socket can lose a count but never add one. Reported, not raised: the
        # job is already in the dead set, and a caller that saw a raise would
        # treat the kill as failed and kill it again.
        def record(conn, payload, config: Wurk.configuration)
          Lua::Loader.eval_once(conn, :count_death, keys: [Keys::STAT_DEATHS],
                                                    argv: [field(payload), MAX_SERIES, OVERFLOW])
        rescue RedisClient::Error => e
          config.handle_exception(e, context: 'dead-set death counter')
        end

        # The hash field for one payload: JSON `[queue, class]`.
        def field(payload)
          job = payload.is_a?(::String) ? parse(payload) : payload
          job = {} unless job.is_a?(::Hash)
          ::JSON.generate([label(job['queue']) || UNKNOWN, label(job['wrapped']) || label(job['class']) || UNKNOWN],
                          script_safe: true)
        end

        # `[[{ 'queue' => q, 'class' => c }, count], …]` from an HGETALL reply
        # (a Hash under RESP3, a flat Array under RESP2), sorted by labels. Two
        # fields that decode to the same labels (escaped differently by another
        # writer) are summed.
        def samples(reply)
          pairs = reply.is_a?(::Hash) ? reply : Array(reply).each_slice(2)
          totals = ::Hash.new(0)
          pairs.each { |raw, count| totals[labels(raw)] += count.to_i }
          totals.sort_by { |labels, _| labels.values }
        end

        private

        def parse(payload)
          ::JSON.parse(payload)
        rescue ::JSON::ParserError
          nil
        end

        def label(value)
          value if value.is_a?(::String) && !value.empty?
        end

        def labels(raw)
          queue, klass = parse(raw)
          { 'queue' => label(queue) || UNKNOWN, 'class' => label(klass) || UNKNOWN }
        end
      end
    end
  end
end
