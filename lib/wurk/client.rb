# frozen_string_literal: true

require_relative 'iterable_job'
require_relative 'job_util'
require_relative 'lua'
require_relative 'status'

module Wurk
  # Enqueue interface. Pipelined LPUSH / ZADD writes against the canonical
  # Sidekiq Redis schema — never change keys, JSON shape, or score format here:
  # wire-compat is sacred. Most apps enqueue through the {Wurk::Worker} DSL
  # (`MyJob.perform_async`), which routes here; reach for Client directly only to
  # push a raw job hash or to drive the bulk/scheduled path explicitly.
  #
  # @example Push a raw job hash
  #   Wurk::Client.new.push("class" => "MyJob", "args" => [1, 2], "queue" => "default")
  # @example Bulk enqueue in one round-trip
  #   Wurk::Client.new.push_bulk("class" => "MyJob", "args" => [[1], [2], [3]])
  #
  # Spec: docs/target/sidekiq-free.md §7.
  class Client # rubocop:disable Metrics/ClassLength
    include JobUtil

    # Sidekiq mirrors these exactly. Tests against the upstream parity suite
    # depend on the magic numbers, not just behavior.
    DEFAULT_BATCH_SIZE        = 1_000
    SCHEDULED_BATCH_SIZE      = 100
    SPREAD_INTERVAL_FLOOR     = 5

    # Batched (`bid`) payloads per EVALSHA pipeline. Ours, not Sidekiq's — it
    # has no batches. Sized to DEFAULT_BATCH_SIZE so no existing caller's
    # round-trip count moves: `push_bulk` already hands #raw_push at most that
    # many payloads, so its batched pipeline stays exactly one round trip.
    #
    # The cap is for the one path that isn't pre-sliced: `autoflush = true`
    # buffers a whole `Batch#jobs` block, so #flush_batched can be handed an
    # unbounded payload set. Unsliced that is one pipeline holding every
    # command and every reply in memory at once, and — Lua being atomic and
    # single-threaded — one uninterrupted server-side sweep that blocks every
    # other client for its duration. Same reasoning as the LIMIT on
    # RELIABLE_SCHEDULE_PROMOTE.
    BATCH_PIPELINE_SLICE      = 1_000

    # Thread-local slot holding the payloads of the current push whose Redis
    # write is confirmed applied. {Client::Buffered} subtracts them from the set
    # it re-buffers when a *later* phase of the same push loses the connection,
    # so an already-written job is never replayed into a second copy.
    # Thread-local because one Client instance serves every producer thread;
    # opened and closed by Buffered, the only reader, so an un-prepended Client
    # pays a single nil check per write phase.
    DELIVERED_KEY = :wurk_client_delivered

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

    # @param item [Hash] job payload; must carry `class` and `args`, may carry `at`, `queue`, `jid`, etc.
    # @return [String, nil] jid; nil when client middleware halts the push.
    def push(item)
      normed  = normalize_item(item)
      payload = invoke_chain(normed)
      return nil unless payload

      verify_json(payload)
      buffered = raw_push([payload])
      emit_enqueued([payload], buffered)
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

    # #push and #push_bulk verify at different points and both match Sidekiq
    # exactly: push walks the payload the chain handed back (sidekiq
    # client.rb:101 — normalize → middleware → verify → raw_push), bulk walks it
    # inside the innermost block (sidekiq client.rb:165). Push used to do both,
    # and since `strict_args_mode` defaults to :raise the second full recursive
    # args walk was never skipped.
    #
    # Bulk keeps its walk inside the block on purpose: a client middleware that
    # halts the job there short-circuits the walk, and hoisting it out would
    # raise on args that middleware was about to drop.
    def invoke_chain(normed)
      @chain.invoke(normed['class'], normed, normed['queue'], pool) { normed }
    end

    def invoke_chain_verified(normed)
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
          buffered = raw_push(compacted)
          emit_enqueued(compacted, buffered)
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
        invoke_chain_verified(normed)
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
    #
    # Returns the payloads it did NOT get to Redis: always nil here, since a
    # plain Client either writes them all or raises. {Client::Buffered}
    # overrides the contract — the payloads it diverted into the outage buffer
    # come back so #push can keep them out of the enqueued metric.
    def raw_push(payloads)
      # Test modes short-circuit the Redis write (and the batch buffer): :fake
      # collects payloads in-memory, :inline runs them now. Client middleware
      # has already run by this point, matching Sidekiq.
      if ::Wurk::Testing.enabled?
        ::Wurk::Testing.dispatch_push(payloads)
        return nil
      end

      buffer = Thread.current[Wurk::Batch::BUFFER_KEY]
      return buffer_add(buffer, payloads) if buffer && payloads.all? { |p| p['bid'] && !p['at'] }

      # No apply-safety claim: every command below appends (LPUSH, ZADD, the
      # batch Lua's counters), so a block replayed after a lost reply is a
      # second copy of the job. A post-write timeout raises out of here instead
      # — {Client::Buffered} turns that into an outage-buffer entry, and a plain
      # Client hands it to whoever called `perform_async`. The pool's pre-apply
      # retry only fires while this block has landed nothing, so a queue group
      # that already went out is never re-pushed by a replay.
      pool.with { |conn| atomic_push(conn, payloads) }
      nil
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
        push_scheduled_split(conn, payloads)
      else
        push_immediate(conn, payloads)
      end
    end

    # Scheduled payloads split like push_immediate: a `bid`-carrying job (a
    # `perform_in` inside `batch.jobs`) must register into its batch at creation
    # via BATCH_SCHEDULE so `total`/`pending` move now — a bare ZADD would leave
    # the batch counters at zero and the empty-marker check would misfire. Plain
    # scheduled jobs take the bare ZADD. Separate pipelines for the same
    # NOSCRIPT-replay reason as push_immediate: a Lua NOSCRIPT surfaces only at
    # pipeline finalize, so a unified retry would replay the plain ZADD and
    # duplicate the scheduled entry.
    def push_scheduled_split(conn, payloads)
      batched, plain = payloads.partition { |j| j['bid'] }
      unless plain.empty?
        conn.pipelined { |pipe| push_scheduled(pipe, plain) }
        mark_delivered(plain)
      end
      push_batched_scheduled_pipelined(conn, batched) unless batched.empty?
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
      push_plain(conn, plain, now) unless plain.empty?
      push_batched_pipelined(conn, batched, now) unless batched.empty?
    end

    # One pipeline per BATCH_PIPELINE_SLICE payloads, each marked delivered the
    # moment its reply is in — same contract as push_plain_group, and for the
    # same reason: a slice that Redis already accepted must stay out of the
    # reliable_push ledger, or a later slice's failure would report it as
    # undelivered.
    def push_batched_pipelined(conn, batched, now)
      batched.each_slice(BATCH_PIPELINE_SLICE) do |slice|
        eval_batched_slice(conn) { |pipe, eval_method| push_batched(pipe, slice, now, eval_method: eval_method) }
        mark_delivered(slice)
      end
    end

    # Same slicing and NOSCRIPT recovery as push_batched_pipelined, for the
    # scheduled batched path (BATCH_SCHEDULE instead of BATCH_PUSH).
    def push_batched_scheduled_pipelined(conn, batched)
      batched.each_slice(BATCH_PIPELINE_SLICE) do |slice|
        eval_batched_slice(conn) { |pipe, eval_method| push_batched_scheduled(pipe, slice, eval_method: eval_method) }
        mark_delivered(slice)
      end
    end

    # Outside of test boots and `SCRIPT FLUSH` the rescue branch is dead
    # code; the eager `script_load_all` after fork keeps the script cache
    # hot for the life of the connection. The retry uses EVAL (source-embedded)
    # instead of EVALSHA so a freshly-loaded script can't race the retry and
    # NOSCRIPT a second time under heavy CI load (WorkerTest 3.4/7.2 flake).
    # `script_load_all` still primes the cache so the *next* pipeline returns
    # to the EVALSHA fast path.
    #
    # Replaying the slice is safe precisely because every command in it is the
    # same script: a flushed cache NOSCRIPTs all of them and applies none.
    # Recovery is per slice, so the slices already acknowledged above are never
    # re-sent. Mirrors Fetcher::Reliable#requeue_pipelined.
    def eval_batched_slice(conn)
      conn.pipelined { |pipe| yield(pipe, :eval_cached) }
    rescue RedisClient::CommandError => e
      raise unless e.message.to_s.start_with?('NOSCRIPT')

      Wurk::Lua::Loader.script_load_all(conn)
      conn.pipelined { |pipe| yield(pipe, :eval_with_source) }
    end

    # One pipeline per queue, marked delivered the moment its reply is in.
    # A push can die between groups — or land its whole plain phase and then
    # lose the connection in the batched phase above — and whatever Redis
    # already accepted must stay out of the reliable_push buffer; replaying it
    # would enqueue a second copy of a job that ran fine.
    #
    # The group in flight when the socket drops stays unmarked and so is
    # replayed: a lost reply is indistinguishable from a lost command, so that
    # residual is at-least-once by construction. The split bounds it to one
    # queue group per failed push instead of the entire payload set.
    #
    # Cost is a round trip per distinct queue. The single-queue push — every
    # `perform_async`, every same-class `push_bulk` — still writes exactly the
    # one SADD + LPUSH pipeline it did before.
    #
    # `uniform_queue` short-circuits the common case (one job, or many jobs
    # all destined for the same queue) without paying for the `group_by`
    # Hash + per-group Array allocations; only a genuinely mixed-queue batch
    # falls through to grouping.
    def push_plain(conn, payloads, now)
      queue = uniform_queue(payloads)
      return push_plain_group(conn, queue, payloads, now) if queue

      payloads.group_by { |j| j['queue'] }.each { |q, jobs| push_plain_group(conn, q, jobs, now) }
    end

    def uniform_queue(payloads)
      first = payloads[0]['queue']
      return first if payloads.size == 1

      first if payloads.all? { |j| j['queue'] == first }
    end

    def push_plain_group(conn, queue, jobs, now)
      serialized = jobs.map do |j|
        j['enqueued_at'] = now
        Wurk.dump_json(j)
      end
      conn.pipelined do |pipe|
        pipe.call('SADD', 'queues', queue)
        pipe.call('LPUSH', "queue:#{queue}", *serialized)
        track_enqueued(pipe, jobs, now)
      end
      mark_delivered(jobs)
    end

    # Ride the pipeline that is already open for the queue write, so a tracked
    # push costs the same round trip an untracked one does. An app that never
    # opts in pays one Hash lookup per payload here and appends nothing: the
    # plain push stays exactly the two commands (SADD + LPUSH) it has always
    # been, which is what `rake bench:command_count_tracked_off` asserts.
    #
    # The TTL is resolved once per group, and only when something is actually
    # tracked — an untracked push never reads the config at all.
    def track_enqueued(pipe, jobs, now)
      ttl = nil
      jobs.each do |job|
        next unless job['track']

        ttl ||= Wurk::Status.default_ttl(@config)
        Wurk::Status.enqueued(pipe, job, now, ttl: ttl)
      end
    end

    # Batched jobs route through BATCH_PUSH: increments b-<bid> total+pending,
    # SADDs jid into the live set, registers the queue, LPUSHes the payload —
    # all atomically. The Lua binds per-job KEYS, so grouping N jobs into one
    # EVALSHA isn't available; they ride one pipeline instead (the `conn` here
    # is always the pipeline #push_batched_pipelined opened), so the cost is
    # N commands and one round trip, not N round trips. `eval_method` is the
    # Wurk::Lua::Loader entry point (`:eval_cached` for the hot EVALSHA path,
    # `:eval_with_source` for the EVAL-source retry) — neither reads the reply,
    # which is what makes the pipelined form legal: `eval_cached`'s inline
    # NOSCRIPT rescue can't fire against a buffered call, so recovery is the
    # caller's finalize-time rescue.
    def push_batched(conn, payloads, now, eval_method: :eval_cached)
      payloads.each do |j|
        j['enqueued_at'] = now
        Wurk::Lua::Loader.public_send(
          eval_method,
          conn,
          :batch_push,
          keys: ["b-#{j['bid']}", "b-#{j['bid']}-jids", "queue:#{j['queue']}", 'queues',
                 "b-#{j['bid']}-died", 'dead-batches'],
          argv: [j['queue'], j['jid'], Wurk.dump_json(j), j['bid'], Wurk::Batch::DEFAULT_EXPIRY_SECONDS]
        )
      end
      # Same pipeline, so a batched tracked push keeps its one round trip too.
      # This slice is the one that gets replayed on NOSCRIPT (see
      # #eval_batched_slice); HSET + EXPIRE are idempotent, so a replay writes
      # the same row twice rather than double-counting anything.
      track_enqueued(conn, payloads, now)
    end

    # Scheduled batched jobs route through BATCH_SCHEDULE: the SADD-guarded
    # total/pending increment registers the job in its batch at creation, and
    # the ZADD defers it onto `schedule`. Payload is stripped of `at`/
    # `enqueued_at` exactly like push_scheduled — `enqueued_at` is stamped fresh
    # at promotion, never while the job sits scheduled (spec §7.1). Per-job
    # KEYS again, so one EVALSHA per job — pipelined by
    # #push_batched_scheduled_pipelined into one round trip per slice.
    def push_batched_scheduled(conn, payloads, eval_method: :eval_cached)
      payloads.each do |j|
        Wurk::Lua::Loader.public_send(
          eval_method,
          conn,
          :batch_schedule,
          keys: ['schedule', "b-#{j['bid']}", "b-#{j['bid']}-jids"],
          argv: [j['at'].to_s, Wurk.dump_json(j.except('enqueued_at', 'at')), j['jid'],
                 Wurk::Batch::DEFAULT_EXPIRY_SECONDS]
        )
      end
    end

    def pool
      @redis_pool || Thread.current[:wurk_via_pool] || @config.redis_pool
    end

    # Record a write Redis has acknowledged, for {Client::Buffered} to subtract
    # from what it re-buffers: one push spans several pipelines (plain vs
    # batched, immediate vs scheduled), and the ledger is what keeps a group
    # that already landed out of the buffer when a later group fails. It
    # accumulates across pool attempts and is never pruned — #raw_push claims no
    # apply-safety, and RedisPool refuses to replay such a block once one of its
    # round trips has completed, so the only replay left starts from an empty
    # ledger.
    def mark_delivered(payloads)
      Thread.current[DELIVERED_KEY]&.concat(payloads)
    end

    # Best-effort `sidekiq.jobs.enqueued` counter — one increment per payload
    # that actually made it past middleware AND Redis. Tags follow the same
    # `worker:`/`queue:` shape as Wurk::Metrics::Statsd so dashboards built
    # for the server-side emissions work unchanged.
    #
    # `buffered` is what reliable_push swallowed into its outage buffer (see
    # #raw_push). Those payloads are not enqueued: the ring buffer may still
    # evict them, and the drain that does land one counts it then — so booking
    # them here would inflate the counter on an outage and double-count every
    # payload that later replays.
    #
    # Resolve the client once for the whole batch and bail before touching a
    # payload: unconfigured is the common case, and the tags below cost two
    # Strings and an Array per job for `increment` to immediately drop.
    def emit_enqueued(payloads, buffered = nil)
      return if Wurk::Metrics::Statsd.safe_client.nil?

      payloads = reject_by_identity(payloads, buffered) if buffered && !buffered.empty?
      payloads.each do |p|
        Wurk::Metrics::Statsd.increment(
          'jobs.enqueued',
          tags: ["worker:#{p['class']}", "queue:#{p['queue']}"]
        )
      end
    end

    # Set difference by object identity — `==` would fold two jobs carrying the
    # same fields into one. Both sides are always the very Hash objects this
    # push built, so identity is both exact and cheaper than hashing them.
    def reject_by_identity(payloads, excluded)
      seen = {}.compare_by_identity
      excluded.each { |p| seen[p] = true }
      payloads.reject { |p| seen.key?(p) }
    end
  end
end
