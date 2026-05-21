# frozen_string_literal: true

require_relative 'job_record'

module Wurk
  # Inspects / iterates one named queue against the canonical Sidekiq
  # schema: LIST at `queue:<name>`, membership in the `queues` SET.
  # Wire-compat is sacred — every Redis call below matches OSS exactly.
  #
  # Pause/unpause is a Pro feature upstream; Wurk ships it free. Membership
  # of the `paused` SET drives both `paused?` and the fetcher's queue filter
  # (see `Wurk::Fetcher::Reliable#queues_cmd`). In-flight jobs continue to
  # completion — pausing only stops new fetches.
  #
  # Spec: docs/target/sidekiq-free.md §19.2, sidekiq-pro.md §6.
  class Queue
    include Enumerable

    # Page size for LRANGE traversal. Matches upstream so dashboards
    # observing Redis traffic see the same pattern.
    PAGE_SIZE = 50

    attr_reader :name
    alias id name

    # @return [Array<Queue>] one per known queue, sorted by name.
    def self.all
      names = Wurk.redis { |conn| conn.call('SMEMBERS', Keys::QUEUES_SET) }
      names.sort.map { |n| new(n) }
    end

    def initialize(name = 'default')
      @name = name.to_s
      @rname = Keys.queue(@name)
    end

    def size
      Wurk.redis { |conn| conn.call('LLEN', @rname) }
    end

    # Seconds since the oldest job (tail of LIST) was enqueued. 0.0 when empty.
    def latency
      payload = Wurk.redis { |conn| conn.call('LRANGE', @rname, -1, -1).first }
      return 0.0 if payload.nil?

      JobRecord.latency_from(Wurk.load_json(payload)['enqueued_at'])
    rescue ::JSON::ParserError
      0.0
    end

    # True iff this queue's name is a member of the `paused` SET. Wurk
    # implements the Pro contract for free; fetchers consult the same set.
    def paused?
      Wurk.redis { |conn| conn.call('SISMEMBER', Keys::PAUSED_SET, @name) } == 1
    end

    # Pause new fetches against this queue. Idempotent — `SADD` returns
    # 0 when the name was already present. In-flight jobs are untouched.
    def pause! # rubocop:disable Naming/PredicateMethod
      Wurk.redis { |conn| conn.call('SADD', Keys::PAUSED_SET, @name) }
      true
    end

    # Resume fetches. Idempotent.
    def unpause! # rubocop:disable Naming/PredicateMethod
      Wurk.redis { |conn| conn.call('SREM', Keys::PAUSED_SET, @name) }
      true
    end

    # Paged LRANGE traversal. Yields JobRecord per payload. Continues
    # paging until Redis returns < PAGE_SIZE rows.
    def each
      page = 0
      loop do
        start  = page * PAGE_SIZE
        stop   = start + PAGE_SIZE - 1
        slice  = Wurk.redis { |conn| conn.call('LRANGE', @rname, start, stop) }
        slice.each { |value| yield JobRecord.new(value, @name) }
        break if slice.size < PAGE_SIZE

        page += 1
      end
    end

    # O(n) scan. Returns nil if no job matches.
    def find_job(jid)
      each { |record| return record if record.jid == jid }
      nil
    end

    # UNLINK the list + drop the queue from the `queues` set. Pipelined
    # so a partial failure leaves at most one of the two ops applied.
    # Method name is Sidekiq wire-compat — `clear?` would break the alias.
    def clear # rubocop:disable Naming/PredicateMethod
      Wurk.redis do |conn|
        conn.pipelined do |pipe|
          pipe.call('UNLINK', @rname)
          pipe.call('SREM', Keys::QUEUES_SET, @name)
        end
      end
      true
    end

    def as_json(_options = nil)
      { name: @name }
    end
  end
end
