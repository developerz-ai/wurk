# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'lua'
require_relative 'batch/buffer'
require_relative 'batch/callbacks'

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
  #      middleware (Thread.current[:wurk_current_batch] is the signal) and
  #      pushes them at block exit, each registered via BATCH_PUSH. A hold
  #      keeps the batch from draining while the block is open.
  #   4. Workers ack on success → BATCH_ACK_SUCCESS → pending--.
  #      Death handler acks on permanent failure → BATCH_ACK_COMPLETE.
  #   5. When live jids and pending child batches both hit zero → fire
  #      `:complete`. When pending also hits zero with zero deaths → fire
  #      `:success`.
  #
  # Nested batches: a job opening its OWN batch (`batch.jobs { ... }`)
  # increments live counters on the existing batch. A callback opening its
  # PARENT batch links via parent_bid and adds child BID to b-<bid>-kids.
  class Batch # rubocop:disable Metrics/ClassLength
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

    EMPTY_JOB = 'Sidekiq::Batch::Empty'

    # Set on the current thread (to a Buffer) only inside an autoflush
    # `#jobs` block. Client#raw_push reads it: when present, batched pushes
    # accumulate here instead of round-tripping per job.
    BUFFER_KEY = :wurk_batch_buffer

    # Bids whose `#jobs` hold this thread already owns, so a block nested in
    # another block of the same batch neither takes a second hold nor drops
    # the outer one when it exits.
    HOLDS_KEY = :wurk_batch_holds

    # Prefix of the hold sentinel's member in `b-<bid>-jids`. Real jids are
    # hex, so a sentinel can never collide with one.
    HOLD_PREFIX = 'hold:'

    attr_reader :bid, :parent_bid, :linger, :callback_class
    attr_accessor :description, :callback_queue, :autoflush

    def self.keys_for(bid)
      base = "b-#{bid}"
      [base, *KEY_SUFFIXES.map { |s| "#{base}-#{s}" }]
    end

    # Runs the block with `batch` as the thread's active batch (the client
    # middleware stamps its bid) and `buffer` collecting batched pushes —
    # either may be nil — restoring whatever an enclosing block had set.
    def self.with_thread_batch(batch, buffer)
      previous    = Thread.current[THREAD_KEY]
      prev_buffer = Thread.current[BUFFER_KEY]
      Thread.current[THREAD_KEY] = batch
      Thread.current[BUFFER_KEY] = buffer
      yield
    ensure
      Thread.current[THREAD_KEY] = previous
      Thread.current[BUFFER_KEY] = prev_buffer
    end

    # BATCH_ACK_SUCCESS for `jid`, as Integers: [removed, pending, live, kids].
    # The last three are the fire-gate inputs `Callbacks.maybe_fire` takes.
    def self.ack_success(conn, bid, jid)
      Wurk::Lua::Loader.eval_cached(
        conn, :batch_ack_success,
        keys: ["b-#{bid}", "b-#{bid}-jids", "b-#{bid}-failed", "b-#{bid}-pkids"], argv: [jid]
      ).map(&:to_i)
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
      score, rank = trim_bounds(max: max, timeout: timeout)
      pipe.call('ZREMRANGEBYSCORE', key, '-inf', score)
      pipe.call('ZREMRANGEBYRANK', key, 0, rank)
    end

    # The same two bounds as arguments, for a writer that cannot append to a
    # pipeline: `Wurk::Flow`'s creation script has to trim from inside its own
    # atomic write, and one policy read out of here beats a second copy of the
    # cutoff arithmetic that drifts the day this one changes.
    def self.trim_bounds(max: nil, timeout: nil)
      cutoff = ::Process.clock_gettime(::Process::CLOCK_REALTIME) - (timeout || DEFAULT_EXPIRY_SECONDS)
      ["(#{cutoff}", -(max || INDEX_MAX)]
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
      # Dedup index over `@callbacks`, keyed on the encoded entry. Only the
      # pre-flush staging path feeds it — once flushed, Redis holds the array
      # and BATCH_APPEND_CALLBACK does the deduping — so a batch reopened by
      # bid never pays to build it.
      @callback_index   = Set.new
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
    # count of jids actually removed (idempotent for repeated calls), in one
    # atomic script. Removing the last live jid drains the batch like an ack
    # would, so the callbacks fire here rather than never.
    def remove_jobs(*jids)
      return 0 if jids.empty?

      removed, pending, live, kids = Wurk.redis do |conn|
        Wurk::Lua::Loader.eval_cached(
          conn, :batch_remove_jobs,
          keys: ["b-#{@bid}", "b-#{@bid}-jids", "b-#{@bid}-failed", "b-#{@bid}-pkids"], argv: jids
        )
      end.map(&:to_i)
      Callbacks.maybe_fire(@bid, pending: pending, live: live, kids: kids) if removed.positive?
      removed
    end

    # Mark batch invalid. Pending jobs still exist in their queues; the
    # server middleware short-circuits them when it observes the flag and acks
    # them as successes (spec §12), so the batch still drains and fires.
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

    # Register a callback. Any number of *distinct* callbacks may be attached
    # to one event; re-registering an identical `[event, target, options]`
    # triple is a no-op, and past `CALLBACKS_MAX` entries the registration is
    # dropped with a warning. The callback target may be a Class, "Foo#bar"
    # string spec, or anything responding to `name`. `options` must be
    # JSON-serializable.
    def on(event, callback, options = {})
      sym = event.to_sym
      raise ArgumentError, "invalid event #{event.inspect}" unless VALID_EVENTS.include?(sym)
      raise ArgumentError, 'callback options must be a Hash' unless options.is_a?(Hash)

      entry = [sym.to_s, callback_target(callback), options]
      # Before the first flush the array lives only in memory; after it, Redis
      # is authoritative and `@callbacks` is a stale mirror nothing reads —
      # appending to it there would just leak one entry per registration.
      @flushed_once ? persist_callback!(entry) : stage_callback(entry)
      self
    end

    # Atomic enqueue block (spec §2.3). Inside the block, `Job.perform_async`
    # finds this batch via Thread.current[THREAD_KEY] and stamps `bid` onto the
    # payload; the pushes are collected and flushed at block exit, each
    # through BATCH_PUSH. A block that raises pushes nothing it collected.
    # `autoflush = N` flushes every N jobs instead, trading that atomicity for
    # bounded memory. A block that creates the batch and adds nothing to it —
    # no job, no child batch — synthesises a Batch::Empty no-op (spec §2.3);
    # a block re-entering an existing batch needs none, the batch already has
    # members (or drains when the hold is released).
    #
    # For the whole block the batch carries a hold (BATCH_HOLD), so a job
    # pushed early — a flushed autoflush slice, a scheduled job, a nested
    # child batch — cannot ack the batch empty and fire its callbacks before
    # the rest is in. The hold is released at block exit through the same ack
    # path as a job. When the block that *created* the batch raises, the hold
    # stays: nothing the block collected was pushed, and a batch that fired
    # for whatever slipped out early would be the partial batch §2.3 rules
    # out. A block re-entering an existing batch releases it either way, or
    # the batch's own jobs could never fire it.
    def jobs(&block)
      raise ArgumentError, 'jobs requires a block' unless block

      threshold = autoflush_threshold
      created   = !@flushed_once
      ensure_first_flush!
      with_hold(release_on_error: !created) do
        collect_jobs(threshold, &block)
        enqueue_empty_marker if created && untouched?
      end
      @mutable = false
      self
    end

    private

    # Runs the block with this batch active so the client middleware stamps
    # the bid. Batched pushes accumulate in a Buffer and flush once at exit
    # (only on a normal exit); the per-N flushing happens in Client#raw_push.
    def collect_jobs(threshold)
      buffer = Buffer.new([], threshold)
      Batch.with_thread_batch(self, buffer) do
        yield
        flush_buffer(buffer)
      end
    end

    # Unset (or `true`/`false`) → buffer the whole block (nil threshold,
    # drained at exit); positive Integer → flush every N. Any other value is
    # a config typo (`0`, `-1`, `"5"`) — fail fast instead of silently
    # degrading to "flush at block exit". Checked before anything touches
    # Redis, so a typo never leaves a batch created and held.
    def autoflush_threshold
      return nil if @autoflush.nil? || @autoflush == true || @autoflush == false
      return @autoflush if @autoflush.is_a?(Integer) && @autoflush.positive?

      raise ArgumentError, "autoflush must be true or a positive Integer, got #{@autoflush.inspect}"
    end

    def with_hold(release_on_error:)
      holds     = (Thread.current[HOLDS_KEY] ||= {})
      outermost = !holds.key?(@bid)
      sentinel  = take_hold if outermost
      holds[@bid] = true if outermost
      completed = false
      begin
        yield
        completed = true
      ensure
        holds.delete(@bid) if outermost
        release_hold(sentinel) if sentinel && (completed || release_on_error)
      end
    end

    # Named after the running job when there is one, so a job reclaimed after
    # a SIGKILL mid-block re-takes the *same* hold (BATCH_HOLD's SADD guard
    # makes that a no-op) and its release clears the one the dead run left.
    def take_hold
      sentinel = "#{HOLD_PREFIX}#{Wurk::Context.current[:jid] || SecureRandom.hex(12)}"
      Wurk.redis do |conn|
        Wurk::Lua::Loader.eval_cached(conn, :batch_hold,
                                      keys: ["b-#{@bid}", "b-#{@bid}-jids"], argv: [sentinel, @expires_in])
      end
      sentinel
    end

    # The ack is retried and raises if Redis stays down — a hold left behind
    # means the batch never fires, which the caller has to hear about. The
    # fire after it is reported, not raised: every job is already pushed, and
    # a caller retrying the block would push them all twice.
    def release_hold(sentinel)
      _removed, pending, live, kids = Callbacks.retrying do
        Wurk.redis { |conn| Batch.ack_success(conn, @bid, sentinel) }
      end
      fire_after_release(pending, live, kids)
    end

    def fire_after_release(pending, live, kids)
      Callbacks.retrying { Callbacks.maybe_fire(@bid, pending: pending, live: live, kids: kids) }
    rescue StandardError => e
      Wurk.configuration.handle_exception(e, { context: "batch #{@bid}: firing callbacks at #jobs exit", bid: @bid })
    end

    def flush_buffer(buffer)
      payloads = buffer.drain
      Wurk::Client.new.flush_batched(payloads) unless payloads.empty?
    end

    # Pre-flush counterpart to `persist_callback!`. Entries registered before
    # the first flush only exist in memory until `first_flush_hash` writes the
    # whole array in one HSET, so BATCH_APPEND_CALLBACK never sees them — the
    # same dedup and cap have to be applied here or the very first write can
    # already ship duplicates and an unbounded array.
    #
    # Keyed on the encoded entry, which is what actually lands in the hash:
    # `{a: 1}` and `{'a' => 1}` are one callback once persisted, so they must
    # be one entry here too.
    def stage_callback(entry)
      json = entry.to_json
      return if @callback_index.include?(json)

      if @callbacks.size >= CALLBACKS_MAX
        Wurk.logger.warn("batch #{@bid}: #{entry[0]} callback dropped — #{CALLBACKS_MAX} callback limit reached")
        return
      end

      @callbacks << entry
      @callback_index << json
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
    # stamped `NX` where it is created instead; see lua/batch_push.lua.
    def pipelined_first_flush(pipe, now)
      pipe.call('HSET', "b-#{@bid}", *first_flush_hash(now).flatten)
      pipe.call('EXPIRE', "b-#{@bid}", @expires_in)
      pipe.call('ZADD', 'batches', now.to_s, @bid)
      Batch.trim_index(pipe, 'batches')
      @tags.each { |t| index_tag(pipe, "tags:#{t}") }
      link_to_parent(pipe) if current_parent_bid
    end

    # The reverse index is shared by every batch carrying the tag, so it must
    # outlive the longest-lived of them: NX gives a fresh (or legacy TTL-less)
    # set a clock, GT only ever extends it. `Status#delete` SREMs the bid.
    def index_tag(pipe, key)
      pipe.call('SADD', key, @bid)
      pipe.call('EXPIRE', key, @expires_in, 'NX')
      pipe.call('EXPIRE', key, @expires_in, 'GT')
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

    # Read after the buffer flushed, so `total` reflects everything the block
    # pushed. Scheduled (`perform_in`) jobs count too: BATCH_SCHEDULE moves
    # `total` at creation, so a scheduled-only block is not mistaken for an
    # empty one.
    def untouched?
      total, kids = Wurk.redis do |conn|
        conn.pipelined do |pipe|
          pipe.call('HGET', "b-#{@bid}", 'total')
          pipe.call('SCARD', "b-#{@bid}-kids")
        end
      end
      total.to_i.zero? && kids.to_i.zero?
    end

    # Pushed straight through, never into an enclosing batch's buffer: it has
    # to be live before this block's hold is released. The payload names the
    # class `Sidekiq::Batch::Empty`, the spec's wire name (§2.3) — the alias
    # resolves it here, and Sidekiq Pro can still run it after a swap back.
    def enqueue_empty_marker
      Batch.with_thread_batch(self, nil) do
        Wurk::Client.push('class' => EMPTY_JOB, 'args' => [], 'queue' => 'default', 'retry' => false)
      end
    end

    def cascade_invalidate(bid)
      Wurk.redis do |conn|
        Wurk::Lua::Loader.eval_cached(conn, :batch_invalidate, keys: ["b-#{bid}"], argv: [])
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
