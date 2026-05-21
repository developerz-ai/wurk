# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'lua'

module Wurk
  # Sidekiq Pro Batches. Group jobs, attach success/complete/death callbacks,
  # track progress. Spec: docs/target/sidekiq-pro.md §2.
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

    # Bid is URL-safe base64 of 10 random bytes — matches Sidekiq Pro's BID
    # generator. Length matters: third-party gems that key off bid prefix
    # (sharded batches in Pro 8) inspect the first character.
    BID_BYTES = 10

    VALID_EVENTS = %i[success complete death].freeze

    # The 'live' set tracks jobs that have not yet reached a terminal state.
    # When it's empty, every job has either succeeded or died → `:complete`
    # is allowed to fire.
    KEY_SUFFIXES = %w[jids failed died notify cbsucc kids pkids tags].freeze

    THREAD_KEY = :wurk_current_batch

    attr_reader :bid, :parent_bid
    attr_accessor :description, :callback_queue, :callback_class, :autoflush

    def self.keys_for(bid)
      base = "b-#{bid}"
      [base, *KEY_SUFFIXES.map { |s| "#{base}-#{s}" }]
    end

    def initialize(bid = nil)
      @bid              = bid || SecureRandom.urlsafe_base64(BID_BYTES)
      @existing         = !bid.nil?
      @description      = nil
      @callback_queue   = 'default'
      @callback_class   = nil
      @tags             = []
      @autoflush        = nil
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

      @callbacks << [sym.to_s, callback_target(callback), options]
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

      previous = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = self
      pre_count = job_count
      begin
        block.call
      ensure
        Thread.current[THREAD_KEY] = previous
      end

      enqueue_empty_marker if job_count == pre_count
      @mutable = false
      self
    end

    private

    # First flush writes the core hash, registers in the global `batches`
    # zset, and links tag indexes. Subsequent #jobs invocations skip this
    # — `total` is already there and BATCH_PUSH only increments deltas.
    def ensure_first_flush!
      return if @flushed_once

      now = ::Process.clock_gettime(::Process::CLOCK_REALTIME)
      Wurk.redis { |conn| conn.pipelined { |pipe| pipelined_first_flush(pipe, now) } }
      @parent_bid = current_parent_bid
      @flushed_once = true
    end

    def pipelined_first_flush(pipe, now)
      pipe.call('HSET', "b-#{@bid}", *first_flush_hash(now).flatten)
      pipe.call('EXPIRE', "b-#{@bid}", @expires_in)
      pipe.call('ZADD', 'batches', now.to_s, @bid)
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

    def link_to_parent(pipe)
      pipe.call('SADD', "b-#{current_parent_bid}-kids", @bid)
      pipe.call('SADD', "b-#{current_parent_bid}-pkids", @bid)
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
      @description    = nil_if_empty(data['description'])
      @callback_queue = data['callback_queue'].to_s.empty? ? 'default' : data['callback_queue']
      @callback_class = nil_if_empty(data['callback_class'])
      @parent_bid     = nil_if_empty(data['parent_bid'])
      @tags           = parse_json_array(data['tags'])
      @callbacks      = parse_json_callbacks(data['callbacks'])
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
