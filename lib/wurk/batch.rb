# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'lua'
require_relative 'batch/buffer'

module Wurk
  # Sidekiq Pro Batches. Group jobs, attach success/complete/death callbacks,
  # track progress. Spec: docs/target/sidekiq-pro.md §2.
  #
  # @example Define a batch with a success callback
  #   batch = Sidekiq::Batch.new
  #   batch.description = "Nightly import"
  #   batch.on(:success, ImportCallback, "user_id" => user.id)
  #   batch.jobs do
  #     rows.each { |r| ImportRowJob.perform_async(r.id) }
  #   end
  #   batch.bid   # => the batch id, persisted in Redis
  #
  # Lifecycle:
  #   1. `Batch.new` allocates a fresh BID; the batch is `mutable?` until the
  #      first `#jobs` block flushes — that flush HSETs the core hash, ZADDs
  #      to `batches`, and writes tag indexes.
  #   2. `Batch.new(bid)` reopens an existing batch (legal from inside a job
  #      or callback only). `mutable?` is false because reopening implies the
  #      first flush already happened.
  #   3. `#jobs { ... }` collects `Job.perform_async` calls via the client
  #      middleware (Thread.current[:wurk_current_batch] is the signal),
  #      atomically registering each via BATCH_PUSH.
  #   4. Workers ack on success → BATCH_ACK_SUCCESS → pending--.
  #      Death handler acks on permanent failure → BATCH_ACK_COMPLETE.
  #   5. When live jids hits zero → fire `:complete`. When pending also
  #      hits zero with zero deaths → fire `:success`.
  #
  # Nested batches: a job opening its OWN batch (`batch.jobs { ... }`)
  # increments live counters on the existing batch. A callback opening its
  # PARENT batch links via parent_bid and adds child BID to b-<bid>-kids.
  class Batch
    DEFAULT_EXPIRY_SECONDS = 30 * 24 * 60 * 60
    POST_SUCCESS_EXPIRY_SECONDS = 24 * 60 * 60
    CALLBACK_NOTIFY_TTL = 30 * 24 * 60 * 60

    # Member ceiling for the two batch index ZSETs (`batches`, `dead-batches`).
    # The score axis in `.trim_index` retires entries in step with the batch data
    # itself, so this is only the backstop for a workload creating batches faster
    # than that window retires them. Deliberately generous: a cap that bites drops
    # batches whose data is still live out of `BatchSet`, and at this scale the
    # per-batch hashes dwarf the index anyway.
    INDEX_MAX = 1_000_000

    # Ceiling on the `callbacks` array of one batch hash, enforced by
    # BATCH_APPEND_CALLBACK. Every registration re-encodes the whole array,
    # and every entry becomes a callback job when the event fires, so an
    # unbounded array is both a hot-path cost and a fan-out. Far above any
    # legitimate batch — real ones register a handful — so hitting it means a
    # loop is registering callbacks it should have registered once.
    CALLBACKS_MAX = 1_000

    # Bid is URL-safe base64 of 10 random bytes — matches Sidekiq Pro's BID
    # generator. Length matters: third-party gems that key off bid prefix
    # (sharded batches in Pro 8) inspect the first character.
    BID_BYTES = 10

    VALID_EVENTS = %i[success complete death].freeze

    # Every key a batch owns, for the sweep paths: `Status#delete` (UNLINK),
    # `Callbacks#apply_linger` and `DeathHandler.restamp_ttls` (EXPIRE).
    #
    # The 'live' set tracks jobs that have not yet reached a terminal state.
    # When it's empty, every job has either succeeded or died → `:complete`
    # is allowed to fire.
    #
    # `complete`/`success`/`death` are the callback dedup markers written by
    # `Callbacks#dedup_set`; they belong to the batch and must die with it.
    # `notify`/`cbsucc`/`tags` are Sidekiq Pro's own key layout (spec §2.8) that
    # Wurk never writes — Wurk dedups on the three markers above and indexes
    # tags at `tags:<tag>`. They stay listed so a Redis dataset carried over
    # from Sidekiq Pro on the gem swap gets swept too; EXPIRE/UNLINK of a
    # missing key is a no-op for batches Wurk created itself.
    KEY_SUFFIXES = %w[jids failed died complete success death notify cbsucc kids pkids tags].freeze

    THREAD_KEY = :wurk_current_batch

    # Set on the current thread (to a Buffer) only inside an autoflush
    # `#jobs` block. Client#raw_push reads it: when present, batched pushes
    # accumulate here instead of round-tripping per job.
    BUFFER_KEY = :wurk_batch_buffer

    attr_reader :bid, :parent_bid, :linger, :callback_class
    attr_accessor :description, :callback_queue, :autoflush

    def self.keys_for(bid)
      base = "b-#{bid}"
      [base, *KEY_SUFFIXES.map { |s| "#{base}-#{s}" }]
    end

    # Two-axis trim of a batch index ZSET (`batches`, `dead-batches`), in the
    # shape of the morgue trim (`DeadSet#trim`): `ZREMRANGEBYSCORE` evicts
    # entries older than `timeout`, `ZREMRANGEBYRANK 0 -max` caps the member
    # count — and, like the morgue, that bound keeps `max - 1` of a full set.
    # Appended to the caller's pipeline so bounding the index costs neither
    # writer an extra round trip.
    #
    # Nothing else ever shrinks either set: `Status#delete` and the
    # death-recovery `ZREM` are manual, so an index entry outlives the batch it
    # points at and both sets grow for the life of the Redis without this.
    #
    # Both index in epoch seconds — `batches` from CLOCK_REALTIME,
    # `dead-batches` from `Time.now.to_f` — so one cutoff serves both. The
    # default window is the batch hash TTL: past it `b-<bid>` is gone and the
    # entry only yields an empty Status. A batch that overrode `expires_in`
    # beyond that window outlives its index entry — still reachable by bid,
    # just no longer enumerated by `BatchSet`.
    #
    # `max:` / `timeout:` override the defaults for one call, so parallel tests
    # can drive the trim on isolated limits without mutating the process-global
    # `Wurk.configuration`.
    def self.trim_index(pipe, key, max: nil, timeout: nil)
      cutoff = ::Process.clock_gettime(::Process::CLOCK_REALTIME) - (timeout || DEFAULT_EXPIRY_SECONDS)
      pipe.call('ZREMRANGEBYSCORE', key, '-inf', "(#{cutoff}")
      pipe.call('ZREMRANGEBYRANK', key, 0, -(max || INDEX_MAX))
    end

    def initialize(bid = nil)
      @bid              = bid || SecureRandom.urlsafe_base64(BID_BYTES)
      @existing         = !bid.nil?
      @description      = nil
      @callback_queue   = 'default'
      @callback_class   = nil
      @tags             = []
      @autoflush        = nil
      @linger           = nil
      @parent_bid       = nil
      @callbacks        = []
      @expires_in       = DEFAULT_EXPIRY_SECONDS
      @mutable          = !@existing
      @flushed_once     = @existing
      load_existing! if @existing
    end

    # Hash assignment writes strings — Sidekiq's UI / third-party gems
    # expect String tags. Array-coercion lets callers pass a String or Set.
    def tags=(value)
      @tags = Array(value).map(&:to_s)
    end

    def tags
      @tags.dup
    end

    # Per-batch post-success retention override (seconds). nil falls back to
    # POST_SUCCESS_EXPIRY_SECONDS when `:success` fires. See §2.8.
    #
    # After the first flush the value is persisted to `b-<bid>`; `apply_linger`
    # reads from Redis, so a setter that only touched memory would silently
    # ignore the override for any batch reopened by bid.
    def linger=(duration)
      @linger = duration&.to_i
      return unless @flushed_once

      Wurk.redis { |conn| conn.call('HSET', "b-#{@bid}", 'linger', @linger.to_s) }
    end

    # Supplies the class for a class-less `"#method"` callback spec (§2.2).
    # Accepts a Class or a String and stores a String either way, so the
    # in-memory value matches what a batch reopened by bid reads back — and so
    # `CallbackJob` never has to care which form the caller used.
    def callback_class=(value)
      @callback_class = value.nil? ? nil : callback_target(value)
    end

    def parent
      return nil if @parent_bid.nil? || @parent_bid.empty?

      Batch.new(@parent_bid)
    end

    def mutable?
      @mutable
    end

    def include?(jid)
      Wurk.redis { |conn| conn.call('SISMEMBER', "b-#{@bid}-jids", jid) }.to_i.positive?
    end

    # Remove jobs from the batch. Decrements pending/total by exactly the
    # count of jids actually removed (idempotent for repeated calls).
    def remove_jobs(*jids)
      return 0 if jids.empty?

      Wurk.redis do |conn|
        removed = conn.call('SREM', "b-#{@bid}-jids", *jids).to_i
        if removed.positive?
          conn.call('HINCRBY', "b-#{@bid}", 'pending', -removed)
          conn.call('HINCRBY', "b-#{@bid}", 'total', -removed)
        end
        removed
      end
    end

    # Mark batch invalid. Pending jobs still exist in their queues; the
    # server middleware short-circuits them when it observes the flag.
    # Cascades to descendant batches via b-<bid>-kids.
    def invalidate_all
      cascade_invalidate(@bid)
      nil
    end

    def valid?
      Wurk.redis { |conn| conn.call('HGET', "b-#{@bid}", 'invalidated') } != '1'
    end

    def status
      Status.new(@bid)
    end

    def expires_in(duration)
      @expires_in = duration.to_i
      self
    end

    # Register a callback. Multiple callbacks of the same event are allowed.
    # The callback target may be a Class, "Foo#bar" string spec, or anything
    # responding to `name`. `options` must be JSON-serializable.
    def on(event, callback, options = {})
      sym = event.to_sym
      raise ArgumentError, "invalid event #{event.inspect}" unless VALID_EVENTS.include?(sym)
      raise ArgumentError, 'callback options must be a Hash' unless options.is_a?(Hash)

      entry = [sym.to_s, callback_target(callback), options]
      @callbacks << entry
      persist_callback!(entry) if @flushed_once
      self
    end

    # Atomic enqueue block. Inside the block, `Job.perform_async` finds
    # this batch via Thread.current[THREAD_KEY] and stamps `bid` onto the
    # payload — the client middleware then uses BATCH_PUSH to register and
    # push atomically. Empty blocks synthesise a Batch::Empty no-op so
    # callbacks still fire.
    def jobs(&block)
      raise ArgumentError, 'jobs requires a block' unless block

      ensure_first_flush!
      pre_count = job_count
      collect_jobs(&block)
      # By the time we check, the buffer (if any) has flushed, so `total`
      # reflects everything the block pushed — a flat count is reliable.
      # Scheduled (`perform_in`) jobs count here too: BATCH_SCHEDULE moves
      # `total` at creation, so a scheduled-only block does not misfire the
      # marker as if it were empty.
      enqueue_empty_marker if job_count == pre_count
      @mutable = false
      self
    end

    private

    # Runs the block with this batch active so the client middleware stamps
    # the bid. With autoflush on, batched pushes accumulate in a Buffer and
    # flush once at exit; the per-N flushing happens in Client#raw_push.
    def collect_jobs
      previous    = Thread.current[THREAD_KEY]
      prev_buffer = Thread.current[BUFFER_KEY]
      buffer      = new_buffer
      Thread.current[THREAD_KEY] = self
      Thread.current[BUFFER_KEY] = buffer
      begin
        yield
        flush_buffer(buffer) if buffer
      ensure
        Thread.current[THREAD_KEY] = previous
        Thread.current[BUFFER_KEY] = prev_buffer
      end
    end

    # Buffering is opt-in via `autoflush`: `true` buffers the whole block and
    # flushes once at exit; a positive Integer flushes every N jobs. Anything
    # falsy keeps the default per-job immediate push.
    def new_buffer
      return nil unless @autoflush

      Buffer.new([], autoflush_threshold)
    end

    # `true` → buffer the whole block (nil threshold, drained at exit);
    # positive Integer → flush every N. Any other truthy value is a config
    # typo (`0`, `-1`, `"5"`) — fail fast instead of silently degrading to
    # "flush at block exit".
    def autoflush_threshold
      return nil if @autoflush == true
      return @autoflush if @autoflush.is_a?(Integer) && @autoflush.positive?

      raise ArgumentError, "autoflush must be true or a positive Integer, got #{@autoflush.inspect}"
    end

    def flush_buffer(buffer)
      payloads = buffer.drain
      Wurk::Client.new.flush_batched(payloads) unless payloads.empty?
    end

    # Like `linger=`, anything registered after the first flush must reach
    # Redis — `Callbacks.enqueue_callbacks` reads specs from the hash, so an
    # in-memory-only append would silently never fire (#213). Covers both
    # `on` after `#jobs` and batches reopened by bid. The append runs
    # server-side (Lua) so concurrent registrations from different processes
    # can't lose each other to a read-modify-write race, and it dedups
    # identical triples so the reopen-per-job shape stops growing the array.
    def persist_callback!(entry)
      event = entry[0]
      status = Wurk.redis do |conn|
        Wurk::Lua::Loader.eval_cached(conn, :batch_append_callback,
                                      keys: ["b-#{@bid}"], argv: [entry.to_json, event, CALLBACKS_MAX])
      end
      raise ArgumentError, "cannot register #{event} callback: batch #{@bid} no longer exists" if status == -1

      # Sentinels are Integers, the fired flag is the String the `<event>`
      # hash field holds — asymmetric on purpose, so a sentinel can never be
      # read as a fired event.
      case status
      when -2
        Wurk.logger.warn("batch #{@bid}: #{event} callback dropped — #{CALLBACKS_MAX} callback limit reached")
      when '1'
        Wurk.logger.warn("batch #{@bid}: #{event} callback registered after #{event} already fired — it will never run")
      end
    end

    # First flush writes the core hash, registers in the global `batches`
    # zset, and links tag indexes. Subsequent #jobs invocations skip this
    # — `total` is already there and BATCH_PUSH only increments deltas.
    def ensure_first_flush!
      return if @flushed_once

      now = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
      Wurk.redis { |conn| conn.pipelined { |pipe| pipelined_first_flush(pipe, now) } }
      @parent_bid = current_parent_bid
      @flushed_once = true
      # Pro statsd metric (spec §9.3); no-op without a dogstatsd client.
      Wurk::Metrics::Statsd.increment('batch.created')
    end

    # Only `b-#{@bid}` is stamped here — none of the sub-keys exist yet at first
    # flush (BATCH_PUSH/BATCH_SCHEDULE create `-jids`, the acks create
    # `-failed`/`-died`), and EXPIRE on a missing key is a no-op. Each key is
    # stamped `NX` where it is created instead; see BATCH_PUSH in lua.rb.
    def pipelined_first_flush(pipe, now)
      pipe.call('HSET', "b-#{@bid}", *first_flush_hash(now).flatten)
      pipe.call('EXPIRE', "b-#{@bid}", @expires_in)
      pipe.call('ZADD', 'batches', now.to_s, @bid)
      Batch.trim_index(pipe, 'batches')
      @tags.each { |t| pipe.call('SADD', "tags:#{t}", @bid) }
      link_to_parent(pipe) if current_parent_bid
    end

    def first_flush_hash(now)
      {
        'created_at' => now.to_s,
        'description' => @description.to_s,
        'callback_queue' => @callback_queue.to_s,
        'callback_class' => @callback_class.to_s,
        'parent_bid' => current_parent_bid.to_s,
        'tags' => @tags.to_json,
        'linger' => @linger.to_s,
        'callbacks' => @callbacks.to_json,
        'total' => '0',
        'pending' => '0',
        'failures' => '0'
      }
    end

    # If we're flushing from inside another batch's #jobs block, that
    # parent batch's BID becomes our parent_bid and we get registered into
    # its kids/pkids sets so cascade success/failure is correctly tracked.
    def current_parent_bid
      outer = Thread.current[THREAD_KEY]
      return nil if outer.nil? || outer.bid == @bid

      outer.bid
    end

    # The only place `-kids`/`-pkids` are created, so this is where they get
    # their clock. TTL is the default, not this batch's `@expires_in`: the keys
    # belong to the *parent*, and NX means the first link sets the retention for
    # every sibling that follows.
    def link_to_parent(pipe)
      parent_key = "b-#{current_parent_bid}"
      pipe.call('SADD', "#{parent_key}-kids", @bid)
      pipe.call('SADD', "#{parent_key}-pkids", @bid)
      pipe.call('EXPIRE', "#{parent_key}-kids", DEFAULT_EXPIRY_SECONDS, 'NX')
      pipe.call('EXPIRE', "#{parent_key}-pkids", DEFAULT_EXPIRY_SECONDS, 'NX')
    end

    def job_count
      Wurk.redis { |conn| conn.call('HGET', "b-#{@bid}", 'total') }.to_i
    end

    def enqueue_empty_marker
      require_relative 'batch/empty'
      previous = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = self
      begin
        Wurk::Batch::Empty.perform_async
      ensure
        Thread.current[THREAD_KEY] = previous
      end
    end

    def cascade_invalidate(bid)
      Wurk.redis do |conn|
        Wurk::Lua::Loader.eval_cached(conn, :batch_invalidate, keys: ["b-#{bid}", "b-#{bid}-jids"], argv: [])
        kids = conn.call('SMEMBERS', "b-#{bid}-kids") || []
        kids.each { |child| cascade_invalidate(child) }
      end
    end

    def load_existing!
      data = fetch_hash
      load_meta(data)
      @tags      = parse_json_array(data['tags'])
      @linger    = nil_if_empty(data['linger'])&.to_i
      @callbacks = parse_json_callbacks(data['callbacks'])
    end

    def load_meta(data)
      @description    = nil_if_empty(data['description'])
      @callback_queue = nil_if_empty(data['callback_queue']) || 'default'
      @callback_class = nil_if_empty(data['callback_class'])
      @parent_bid     = nil_if_empty(data['parent_bid'])
    end

    def fetch_hash
      raw = Wurk.redis { |conn| conn.call('HGETALL', "b-#{@bid}") }
      raw.is_a?(Hash) ? raw : raw.each_slice(2).to_h
    end

    def callback_target(callback)
      case callback
      when Class then callback.name
      when String, Symbol then callback.to_s
      else
        raise ArgumentError, "callback must be Class or String: #{callback.inspect}" unless callback.respond_to?(:name)

        callback.name
      end
    end

    def nil_if_empty(val)
      val.nil? || val.to_s.empty? ? nil : val
    end

    def parse_json_array(raw)
      return [] if raw.nil? || raw.empty?

      JSON.parse(raw)
    rescue JSON::ParserError
      []
    end

    def parse_json_callbacks(raw)
      arr = parse_json_array(raw)
      arr.is_a?(Array) ? arr : []
    end
  end
end

require_relative 'batch/status'
