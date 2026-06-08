# frozen_string_literal: true

require 'json'

module Wurk
  # Read-side data API for IterableJob progress. Bulk-reads the `it-<jid>`
  # HASHes (sidekiq-free.md §1.5) in a single pipeline so dashboards and tools
  # can introspect many iterable jobs without N round trips. The runtime that
  # *writes* those HASHes lives in Wurk::IterableJob; this is the reader.
  #
  # Aliased Sidekiq::IterableJobQuery.
  #
  # Spec: docs/target/sidekiq-free.md §19.9.
  class IterableJobQuery
    include Enumerable

    # One job's iteration state. `raw` is the `it-<jid>` HASH (String=>String);
    # the accessors decode the wire fields (`ex`/`rt`/`c`/`cancelled`, §1.5).
    State = Struct.new(:jid, :raw) do
      def executions = raw['ex'].to_i
      def runtime    = raw['rt'].to_f
      def cursor     = raw['c'] && ::JSON.parse(raw['c'])

      # Epoch-seconds timestamp the job was cancelled at, or nil if it wasn't.
      def cancelled
        ts = raw['cancelled']
        ts && !ts.to_s.empty? ? ts.to_i : nil
      end
    end

    # @param jids [Array<String>] job ids to query.
    def initialize(jids)
      @states = fetch(Array(jids))
    end

    # @return [State, nil] state for jid, or nil when no `it-<jid>` HASH exists
    #   (e.g. a non-iterable job, or one whose state has expired).
    def [](jid) = @states[jid]

    # Yields each present State, in the order its jid was supplied. Jids with no
    # state are skipped — only iterable jobs with live state appear.
    def each(&) = @states.each_value(&)

    private

    def fetch(jids)
      return {} if jids.empty?

      raws = Wurk.redis do |conn|
        conn.pipelined { |pipe| jids.each { |jid| pipe.call('HGETALL', "it-#{jid}") } }
      end
      build_states(jids, raws)
    end

    def build_states(jids, raws)
      states = {}
      jids.each_with_index do |jid, i|
        hash = normalize_hgetall(raws[i])
        states[jid] = State.new(jid, hash) unless hash.empty?
      end
      states
    end

    # redis-client returns HGETALL as a flat array on some adapters and a Hash
    # on others. Normalize to a String-keyed Hash either way (mirrors the
    # normalize done in Wurk::IterableJob#load_state).
    def normalize_hgetall(raw)
      case raw
      when Hash  then raw
      when Array then raw.each_slice(2).to_h
      else            {}
      end
    end
  end
end
