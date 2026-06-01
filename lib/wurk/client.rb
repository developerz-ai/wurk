# frozen_string_literal: true

require_relative 'iterable_job'
require_relative 'job_util'
require_relative 'lua'

module Wurk
  # Enqueue interface. Pipelined LPUSH / ZADD writes against the canonical
  # Sidekiq Redis schema — never change keys, JSON shape, or score format here:
  # wire-compat is sacred.
  #
  # Spec: docs/target/sidekiq-free.md §7.
  class Client
    include JobUtil

    # Sidekiq mirrors these exactly. Tests against the upstream parity suite
    # depend on the magic numbers, not just behavior.
    DEFAULT_BATCH_SIZE        = 1_000
    SCHEDULED_BATCH_SIZE      = 100
    SPREAD_INTERVAL_FLOOR     = 5

    attr_accessor :redis_pool

    def initialize(pool: nil, config: nil, chain: nil)
      @config     = config || Wurk.configuration
      @redis_pool = pool
      @chain      = chain || @config.client_middleware
    end

    # Returns the chain (or a duplicate when a block is given, matching Sidekiq).
    def middleware
      return @chain unless block_given?

      copy = @chain.dup
      yield copy
      copy
    end

    # @return [String, nil] jid; nil when client middleware halts the push.
    def push(item)
      normed  = normalize_item(item)
      payload = invoke_chain(normed)
      return nil unless payload

      verify_json(payload)
      raw_push([payload])
      emit_enqueued([payload])
      payload['jid']
    end

    # @param items [Hash] keys: class, args (Array<Array>), at?, spread_interval?, batch_size?, jid?
    # @return [Array<String, nil>] jids in submission order; nil entries mark middleware-halted jobs.
    def push_bulk(items)
      args = items['args'] || items[:args]
      validate_bulk_shape!(items, args)
      return [] if args.empty?

      at_values = expand_at(items, args.size)
      batch_sz  = items['batch_size'] || items[:batch_size] || (at_values ? SCHEDULED_BATCH_SIZE : DEFAULT_BATCH_SIZE)
      base      = bulk_base(items)
      flush_bulk(args, at_values, base, batch_sz)
    end

    # Marks an IterableJob as cancelled. Returns the Unix epoch timestamp written.
    # Field name + epoch-second value mirror Sidekiq::IterableJob#cancel! exactly.
    # TTL = CANCELLATION_PERIOD so other workers observe the flag well after
    # the dashboard click that issued the cancel.
    def cancel!(jid)
      raise ArgumentError, 'jid must be a non-empty String' if jid.nil? || jid.to_s.empty?

      ts = ::Process.clock_gettime(::Process::CLOCK_REALTIME).to_i
      pool.with do |conn|
        conn.call('HSET', "it-#{jid}", 'cancelled', ts)
        conn.call('EXPIRE', "it-#{jid}", Wurk::IterableJob::CANCELLATION_PERIOD)
      end
      ts
    end

    # Flush batched payloads (each carrying a `bid`) to Redis in one pipeline.
    # Public entry point for Wurk::Batch's autoflush buffer — see #push_batched
    # for the per-job BATCH_PUSH semantics it reuses.
    def flush_batched(payloads)
      return if payloads.empty?

      pool.with { |conn| push_batched_pipelined(conn, payloads, now_in_millis) }
    end

    class << self
      def push(item)        = new.push(item)
      def push_bulk(items)  = new.push_bulk(items)
      def enqueue(klass, *) = klass.perform_async(*)

      def enqueue_to(queue, klass, *)
        klass.set(queue: queue.to_s).perform_async(*)
      end

      def enqueue_to_in(queue, interval, klass, *)
        klass.set(queue: queue.to_s).perform_in(interval, *)
      end

      def enqueue_in(interval, klass, *)
        klass.perform_in(interval, *)
      end

      # Thread-local pool override. Re-entrant calls are rejected — Sidekiq
      # raises here too, because nested `via` would silently shadow. The
      # begin/ensure guards the slot so a raise on entry doesn't clear the
      # outer caller's pool.
      def via(pool)
        raise ArgumentError, 'pool is required' if pool.nil?
        raise 'Wurk::Client.via is not re-entrant' if Thread.current[:wurk_via_pool]

        Thread.current[:wurk_via_pool] = pool
        begin
          yield
        ensure
          Thread.current[:wurk_via_pool] = nil
        end
      end
    end

    private

    def invoke_chain(normed)
      @chain.invoke(normed['class'], normed, normed['queue'], pool) do
        verify_json(normed)
        normed
      end
    end

    def validate_bulk_shape!(items, args)
      raise ArgumentError, "Bulk arguments must be an Array of Arrays: `#{args.inspect}`" unless valid_bulk_args?(args)
      raise ArgumentError, "Job 'jid' is only allowed with a single-job bulk" if explicit_jid?(items) && args.size > 1
      raise ArgumentError, "Cannot pass both 'at' and 'spread_interval'" if conflicting_schedule?(items)
    end

    def conflicting_schedule?(items)
      (items.key?('at') || items.key?(:at)) &&
        (items.key?('spread_interval') || items.key?(:spread_interval))
    end

    def valid_bulk_args?(args)
      args.is_a?(Array) && args.all?(Array)
    end

    def explicit_jid?(items)
      items.key?('jid') || items.key?(:jid)
    end

    def bulk_base(items)
      base = items.transform_keys(&:to_s)
      %w[args at spread_interval batch_size].each { |k| base.delete(k) }
      base
    end

    def flush_bulk(args, at_values, base, batch_size)
      jids = []
      args.each_slice(batch_size).with_index do |slice, slice_index|
        offset  = slice_index * batch_size
        ats     = at_values && at_values[offset, slice.size]
        payloads = build_bulk_payloads(slice, base, ats)
        compacted = payloads.compact
        if compacted.any?
          raw_push(compacted)
          emit_enqueued(compacted)
        end
        jids.concat(payloads.map { |p| p && p['jid'] })
      end
      jids
    end

    def build_bulk_payloads(slice, base, ats)
      slice.each_with_index.map do |job_args, idx|
        item = base.merge('args' => job_args)
        item['at'] = ats[idx] if ats
        normed = normalize_item(item)
        invoke_chain(normed)
      end
    end

    def expand_at(items, count)
      return expand_spread(items, count) unless items.key?('at') || items.key?(:at)

      at = items['at'] || items[:at]
      case at
      when Array
        raise ArgumentError, "'at' array size must match args" unless at.size == count
        raise ArgumentError, "'at' array must contain only Numeric values" unless at.all?(Numeric)

        at
      when Numeric
        Array.new(count, at)
      else
        raise ArgumentError, "'at' must be Numeric or Array<Numeric>"
      end
    end

    def expand_spread(items, count)
      return nil unless items.key?('spread_interval') || items.key?(:spread_interval)

      spread = items['spread_interval'] || items[:spread_interval]
      raise ArgumentError, "'spread_interval' must be positive Numeric" unless spread.is_a?(Numeric) && spread.positive?

      window = [spread.to_f, SPREAD_INTERVAL_FLOOR].max
      now    = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
      Array.new(count) { now + (rand * window) }
    end

    # Inside an autoflush `Batch#jobs` block immediate batched pushes are
    # accumulated in the buffer rather than written; it flushes every N jobs
    # (when autoflush is an Integer) and Batch#jobs drains the remainder at
    # block exit. Scheduled (`at`) or non-batched payloads bypass the buffer.
    #
    # Adds happen one payload at a time so an `autoflush = N` actually bounds
    # the pipeline size — a bulk push of 100 with N=2 must flush 2/2/... not
    # 100 in one shot.
    def raw_push(payloads)
      # Test modes short-circuit the Redis write (and the batch buffer): :fake
      # collects payloads in-memory, :inline runs them now. Client middleware
      # has already run by this point, matching Sidekiq.
      return ::Wurk::Testing.dispatch_push(payloads) if ::Wurk::Testing.enabled?

      buffer = Thread.current[Wurk::Batch::BUFFER_KEY]
      return buffer_add(buffer, payloads) if buffer && payloads.all? { |p| p['bid'] && !p['at'] }

      pool.with { |conn| atomic_push(conn, payloads) }
    end

    # Batch autoflush path: accumulate each non-scheduled batched payload into
    # the active buffer, flushing every N adds (when `buffer.ready?`).
    def buffer_add(buffer, payloads)
      payloads.each do |payload|
        buffer.add([payload])
        flush_batched(buffer.drain) if buffer.ready?
      end
      nil
    end

    def atomic_push(conn, payloads)
      if payloads.first['at']
        conn.pipelined { |pipe| push_scheduled(pipe, payloads) }
      else
        push_immediate(conn, payloads)
      end
    end

    def push_scheduled(conn, payloads)
      args = payloads.flat_map do |hash|
        [hash['at'].to_s, Wurk.dump_json(hash.except('enqueued_at', 'at'))]
      end
      conn.call('ZADD', 'schedule', *args)
    end

    # Plain SADD/LPUSH and Lua BATCH_PUSH must live in separate pipelines.
    # A `NOSCRIPT` from EVALSHA surfaces only at pipeline finalize — never
    # to `eval_cached`'s inline rescue — so an outer retry of a unified
    # pipeline would replay the already-applied plain commands and
    # duplicate non-batched enqueues. Splitting the phases means a Lua
    # script reload only replays the batched pipeline.
    def push_immediate(conn, payloads)
      now = now_in_millis
      batched, plain = payloads.partition { |j| j['bid'] }
      conn.pipelined { |pipe| push_plain(pipe, plain, now) } unless plain.empty?
      push_batched_pipelined(conn, batched, now) unless batched.empty?
    end

    # Outside of test boots and `SCRIPT FLUSH` the rescue branch is dead
    # code; the eager `script_load_all` after fork keeps the script cache
    # hot for the life of the connection.
    def push_batched_pipelined(conn, batched, now)
      attempts = 0
      begin
        conn.pipelined { |pipe| push_batched(pipe, batched, now) }
      rescue RedisClient::CommandError => e
        raise unless e.message.to_s.start_with?('NOSCRIPT')
        raise if attempts.positive?

        attempts += 1
        Wurk::Lua::Loader.script_load_all(conn)
        retry
      end
    end

    def push_plain(conn, payloads, now)
      grouped = payloads.group_by { |j| j['queue'] }
      conn.call('SADD', 'queues', *grouped.keys)
      grouped.each do |queue, jobs|
        serialized = jobs.map do |j|
          j['enqueued_at'] = now
          Wurk.dump_json(j)
        end
        conn.call('LPUSH', "queue:#{queue}", *serialized)
      end
    end

    # Batched jobs route through BATCH_PUSH: increments b-<bid> total+pending,
    # SADDs jid into the live set, registers the queue, LPUSHes the payload —
    # all atomically. One Redis round-trip per job (no pipeline grouping)
    # because the lua needs per-job KEYS bound. Acceptable cost: batch
    # enqueue is not the hot path; correctness is.
    def push_batched(conn, payloads, now)
      payloads.each do |j|
        j['enqueued_at'] = now
        Wurk::Lua::Loader.eval_cached(
          conn,
          :batch_push,
          keys: ["b-#{j['bid']}", "b-#{j['bid']}-jids", "queue:#{j['queue']}", 'queues'],
          argv: [j['queue'], j['jid'], Wurk.dump_json(j)]
        )
      end
    end

    def pool
      @redis_pool || Thread.current[:wurk_via_pool] || @config.redis_pool
    end

    # Best-effort `sidekiq.jobs.enqueued` counter — one increment per payload
    # that actually made it past middleware AND Redis. Tags follow the same
    # `worker:`/`queue:` shape as Wurk::Metrics::Statsd so dashboards built
    # for the server-side emissions work unchanged.
    def emit_enqueued(payloads)
      payloads.each do |p|
        Wurk::Metrics::Statsd.increment(
          'jobs.enqueued',
          tags: ["worker:#{p['class']}", "queue:#{p['queue']}"]
        )
      end
    end
  end
end
