# frozen_string_literal: true

require 'json'
require 'digest'
require 'time'
require_relative 'component'
require_relative 'client'
require_relative 'leader'

module Wurk
  # Sidekiq Enterprise periodic jobs. Pure leader-driven cron — only the
  # elected leader enqueues per tick; followers run nothing. No backfill
  # on restart. DST-aware via per-loop timezone. In-tree crontab parser
  # (no fugit dependency) supporting 5-field expressions plus the standard
  # `@hourly` / `@daily` / `@weekly` / `@monthly` / `@yearly` aliases.
  #
  # Spec: docs/target/sidekiq-ent.md §2.
  #
  # Layout:
  #   * `Cron::Parser` — crontab → wall-clock match + `next_fire_at`. Walks
  #     forward minute-by-minute in the loop's TZ; DST gaps are skipped
  #     naturally because the wall-clock components advance past them.
  #   * `Cron::Loop` — one registered job. Identity = SHA1(schedule+klass+opts)
  #     so a re-registration of the same loop is idempotent.
  #   * `Cron::Manager` — registration DSL. `mgr.register(cron, klass, **opts)`
  #     with `tz=` mass-setter. Writes to Redis (`periodic` SET + `loops:{lid}`
  #     HASH).
  #   * `Cron::LoopSet` — Enumerable view (`each`/`size`/`fetch(lid)`).
  #   * `Cron::ConfigTester` — boot-time validator. Verifies cron syntax and
  #     that every worker class constant resolves.
  #   * `Cron::Poller` — once-per-minute tick loop. `Wurk::Leader` gates
  #     enqueue; non-leaders still parse but never push.
  #
  # Wire-compat: `periodic`, `loops:{lid}`, `loop-history:{lid}`, `cron-leader`
  # — all per docs/target/sidekiq-ent.md §2.7.
  module Cron
    PERIODIC_KEY = 'periodic'
    LOOP_PREFIX = 'loops:'
    HISTORY_PREFIX = 'loop-history:'
    LEADER_KEY = 'cron-leader'

    HISTORY_CAP = 25
    DEFAULT_TICK_SECONDS = 60
    DEFAULT_LEADER_TTL = 30
    MISSED_TICK_THRESHOLD = 90

    # 5-field crontab + `@aliases`. No seconds field, no DOW name aliases
    # (sidekiq-ent §2.2 uses numeric DOW only).
    class Parser
      FIELDS = [
        [0, 59],
        [0, 23],
        [1, 31],
        [1, 12],
        [0, 7]
      ].freeze

      ALIASES = {
        '@hourly' => '0 * * * *',
        '@daily' => '0 0 * * *',
        '@midnight' => '0 0 * * *',
        '@weekly' => '0 0 * * 0',
        '@monthly' => '0 0 1 * *',
        '@yearly' => '0 0 1 1 *',
        '@annually' => '0 0 1 1 *'
      }.freeze

      MAX_LOOKAHEAD_MINUTES = 366 * 24 * 60 * 4

      attr_reader :expression, :fields

      def initialize(expression)
        parts = normalize_expression(expression)
        @expression = parts.join(' ')
        @fields = parts.each_with_index.map { |part, i| parse_field(part, *FIELDS[i]) }
        @dom_restricted = parts[2] != '*'
        @dow_restricted = parts[4] != '*'
      end

      # Smallest UTC epoch strictly greater than `from_epoch` whose wall-clock
      # components in `tz` match every field. Returns nil if no match within
      # ~4 years (a malformed loop like Feb 29 in a non-leap span).
      def next_fire_at(from_epoch, tz = nil)
        t = ((from_epoch.to_i / 60) + 1) * 60
        MAX_LOOKAHEAD_MINUTES.times do
          wc = wall_clock(t, tz)
          return t if match_components?(wc)

          t += 60
        end
        nil
      end

      def match?(time, tz = nil)
        match_components?(wall_clock(time.to_i, tz))
      end

      private

      def match_components?(components)
        min, hour, dom, mon, dow = components
        return false unless @fields[0].include?(min)
        return false unless @fields[1].include?(hour)
        return false unless @fields[3].include?(mon)

        match_day?(dom, dow)
      end

      # Cron quirk (§2.6): if both dom and dow are restricted, OR them so
      # `0 0 13 * 5` matches "Friday the 13th". If only one is set, that
      # one must match. Both wild → always match the day half.
      def match_day?(dom, dow)
        dom_ok = @fields[2].include?(dom)
        dow_ok = @fields[4].include?(dow)
        return dom_ok || dow_ok if @dom_restricted && @dow_restricted
        return dom_ok if @dom_restricted
        return dow_ok if @dow_restricted

        true
      end

      def normalize_expression(expression)
        raise ArgumentError, 'cron expression must be a String' unless expression.is_a?(String)

        normalized = (ALIASES[expression.strip] || expression).strip
        parts = normalized.split(/\s+/)
        return parts if parts.size == 5

        raise ArgumentError, "cron expression must have 5 fields (got #{parts.size}): #{expression.inspect}"
      end

      def parse_field(part, min, max)
        raw = part == '*' ? (min..max).to_a : part.split(',').flat_map { |c| parse_chunk(c, min, max) }
        normalized = raw.map { |v| max == 7 && v == 7 ? 0 : v }
        Set.new(normalized)
      end

      def parse_chunk(chunk, min, max)
        if chunk.include?('/')
          parse_step(chunk, min, max)
        elsif chunk.include?('-')
          parse_range(chunk, min, max)
        else
          v = Integer(chunk)
          validate_value!(v, min, max)
          [v]
        end
      end

      def parse_step(chunk, min, max)
        base, step = chunk.split('/', 2)
        step_i = Integer(step)
        raise ArgumentError, "cron step must be >= 1 (got #{step_i})" if step_i < 1

        base_values = base == '*' ? (min..max).to_a : parse_chunk(base, min, max)
        start = base_values.first
        base_values.select { |v| ((v - start) % step_i).zero? }
      end

      def parse_range(chunk, min, max)
        a, b = chunk.split('-', 2).map { |x| Integer(x) }
        raise ArgumentError, "cron range start > end (#{a} > #{b})" if a > b

        validate_value!(a, min, max)
        validate_value!(b, min, max)
        (a..b).to_a
      end

      def validate_value!(v, min, max)
        return if v.between?(min, max)

        raise ArgumentError, "cron value #{v} out of range #{min}..#{max}"
      end

      # epoch → [min, hour, dom, mon, dow] in `tz`. Accepts:
      #   * nil          → UTC
      #   * AS::TimeZone → responds to #at
      #   * TZInfo::Tz   → responds to #utc_to_local
      #   * IANA String  → parsed via ENV TZ override (POSIX `tzset(3)`)
      def wall_clock(epoch, tz)
        t = case tz
            when nil then ::Time.at(epoch).utc
            else local_time(epoch, tz)
            end
        dow = t.wday
        [t.min, t.hour, t.day, t.mon, dow]
      end

      def local_time(epoch, tz)
        return tz.at(epoch) if tz.respond_to?(:at) && !tz.is_a?(String)
        return tz.utc_to_local(::Time.at(epoch).utc) if tz.respond_to?(:utc_to_local)

        with_tz_env(tz.to_s) { ::Time.at(epoch) }
      end

      def with_tz_env(name)
        old = ENV.fetch('TZ', nil)
        ENV['TZ'] = name
        yield
      ensure
        ENV['TZ'] = old
      end
    end

    # One registered loop. Carries identity, schedule, options, and the
    # cached parser. Immutable after `register!` — re-registering the same
    # (schedule, klass, options) triple no-ops.
    class Loop
      attr_reader :lid, :schedule, :klass, :options, :tz

      def initialize(schedule:, klass:, options: {}, tz: nil, lid: nil)
        raise ArgumentError, 'klass must be a String' unless klass.is_a?(String) && !klass.empty?

        @schedule = schedule
        @klass = klass
        @options = stringify_options(options)
        @tz = tz
        @parser = Parser.new(schedule)
        @lid = lid || Cron.lid(schedule, klass, @options)
      end

      def parser
        @parser ||= Parser.new(@schedule)
      end

      def paused?
        @options['paused'].to_s == '1' || @options['paused'] == true
      end

      def queue
        @options['queue'] || 'default'
      end

      def args
        Array(@options['args'])
      end

      def retry_value
        @options.fetch('retry', true)
      end

      def history
        Wurk.redis do |c|
          entries = c.call('LRANGE', "#{HISTORY_PREFIX}#{@lid}", 0, -1)
          entries.map { |e| JSON.parse(e) }
        end
      end

      def to_redis_hash
        {
          'schedule' => @schedule,
          'klass' => @klass,
          'options' => Wurk.dump_json(@options),
          'tz' => tz_name.to_s,
          'paused' => paused? ? '1' : '0'
        }
      end

      def next_fire_at(from_epoch = ::Time.now.to_i)
        parser.next_fire_at(from_epoch, @tz)
      end

      def tz_name
        return nil if @tz.nil?
        return @tz.name if @tz.respond_to?(:name)
        return @tz.identifier if @tz.respond_to?(:identifier)

        @tz.to_s
      end

      def self.from_redis(lid, hash)
        h = hash.is_a?(Array) ? hash.each_slice(2).to_h : hash
        opts = h['options'] ? JSON.parse(h['options']) : {}
        opts['paused'] = '1' if h['paused'] == '1'
        tz = h['tz'].to_s.empty? ? nil : h['tz']
        new(lid: lid, schedule: h['schedule'], klass: h['klass'], options: opts, tz: tz)
      end

      private

      def stringify_options(opts)
        opts.transform_keys(&:to_s)
      end
    end

    # Registration DSL. One Manager per `config.periodic` block; multiple
    # blocks accumulate. `mgr.tz=` sets the default tz for subsequent
    # `register` calls; per-call `tz:` overrides.
    class Manager
      attr_accessor :tz
      attr_reader :loops

      def initialize(config = nil)
        @config = config
        @loops = []
        @tz = nil
      end

      def register(cron, klass, **opts)
        klass_name = klass.is_a?(String) ? klass : klass.to_s
        tz = opts.delete(:tz) || @tz
        normalized = opts.transform_keys(&:to_s)
        loop_obj = Loop.new(schedule: cron, klass: klass_name, options: normalized, tz: tz)
        @loops << loop_obj
        Cron.persist(loop_obj)
        loop_obj
      end
    end

    # Enumerable view of every registered loop. Reads `periodic` SET +
    # `loops:{lid}` HASH on each iteration — cheap because the dashboard's
    # list view is the only hot caller.
    class LoopSet
      include ::Enumerable

      def initialize(_config = nil); end

      def each
        return enum_for(:each) unless block_given?

        Wurk.redis do |c|
          lids = c.call('SMEMBERS', PERIODIC_KEY)
          lids.each do |lid|
            h = c.call('HGETALL', "#{LOOP_PREFIX}#{lid}")
            next if h.nil? || h.empty?

            yield Loop.from_redis(lid, h)
          end
        end
      end

      def size
        Wurk.redis { |c| c.call('SCARD', PERIODIC_KEY).to_i }
      end

      def fetch(lid)
        h = Wurk.redis { |c| c.call('HGETALL', "#{LOOP_PREFIX}#{lid}") }
        return nil if h.nil? || h.empty?

        h = h.each_slice(2).to_h if h.is_a?(Array)
        return nil if h.empty?

        Loop.from_redis(lid, h)
      end
    end

    # Boot-time validator. Runs the user's periodic block against a
    # disposable Manager whose register call also resolves the klass
    # constant — a typo'd class name surfaces here instead of on the
    # first tick in production.
    class ConfigTester
      def verify(&block)
        raise ArgumentError, 'block required' unless block

        mgr = Manager.new
        block.call(mgr)
        mgr.loops.each { |lp| resolve_klass!(lp.klass) }
        mgr.loops
      rescue StandardError
        # register persists each loop immediately, so a validation failure
        # would otherwise leave partially-applied loops in the live LoopSet —
        # they'd fire on the next poll. Roll the whole batch back, then re-raise.
        mgr&.loops&.each { |lp| Cron.unregister(lp.lid) }
        raise
      end

      private

      def resolve_klass!(klass)
        klass.split('::').inject(Object) { |mod, name| mod.const_get(name) }
      rescue NameError => e
        raise ArgumentError, "Cron worker class #{klass.inspect} could not be resolved: #{e.message}"
      end
    end

    # Once-per-minute tick driver. Leader-only enqueue per loop. Followers
    # still iterate the LoopSet (cheap) so they're warm if leadership
    # transfers mid-tick. Missed-tick warning when wall-clock has drifted
    # more than `MISSED_TICK_THRESHOLD` seconds past the expected fire.
    class Poller
      include Component

      def initialize(config)
        @config = config
        @done = false
        @mutex = ::Mutex.new
        @sleeper = ::ConditionVariable.new
        @leader = Leader.new(key: LEADER_KEY, ttl: DEFAULT_LEADER_TTL)
        @client = Client.new(config: config)
        @thread = nil
        @tick_interval = DEFAULT_TICK_SECONDS
      end

      def start
        @poller_thread ||= safe_thread('cron-poller') do # rubocop:disable Naming/MemoizedInstanceVariableName
          until @done
            tick
            wait
          end
          @leader.release
        end
      end

      def terminate
        @mutex.synchronize do
          @done = true
          @sleeper.signal
        end
      end

      def tick
        @leader.acquire
        return unless @leader.leader?

        LoopSet.new.each { |lp| enqueue_if_due(lp) }
      rescue StandardError => e
        handle_exception(e, { context: 'cron-poller' })
      end

      def enqueue_if_due(loop_obj)
        return if loop_obj.paused?

        now = ::Time.now.to_i
        prev_fire, next_fire = read_fire_marks(loop_obj.lid)
        next_fire ||= loop_obj.next_fire_at(prev_fire || (now - @tick_interval))
        return if next_fire.nil? || next_fire > now

        warn_missed_tick(loop_obj, next_fire, now)
        jid = enqueue!(loop_obj)
        future = loop_obj.next_fire_at(now)
        record_fire(loop_obj, jid, now, future)
        jid
      end

      private

      def wait
        @mutex.synchronize do
          @sleeper.wait(@mutex, @tick_interval) unless @done
        end
      end

      def warn_missed_tick(loop_obj, expected, now)
        return if now - expected <= MISSED_TICK_THRESHOLD

        logger.warn(
          "[cron] missed tick lid=#{loop_obj.lid} klass=#{loop_obj.klass} " \
          "expected_at=#{expected} fired_at=#{now} drift=#{now - expected}s"
        )
      end

      def enqueue!(loop_obj)
        @client.push(
          'class' => loop_obj.klass,
          'args' => loop_obj.args,
          'queue' => loop_obj.queue,
          'retry' => loop_obj.retry_value
        )
      end

      def read_fire_marks(lid)
        Wurk.redis do |c|
          vals = c.call('HMGET', "#{LOOP_PREFIX}#{lid}", 'lf', 'nf')
          [vals[0]&.to_i, vals[1]&.to_i]
        end
      end

      def record_fire(loop_obj, jid, fired_at, future)
        history_entry = Wurk.dump_json([fired_at, jid])
        Wurk.redis do |c|
          c.call('HSET', "#{LOOP_PREFIX}#{loop_obj.lid}", 'lf', fired_at.to_s, 'nf', future.to_s)
          c.call('LPUSH', "#{HISTORY_PREFIX}#{loop_obj.lid}", history_entry)
          c.call('LTRIM', "#{HISTORY_PREFIX}#{loop_obj.lid}", 0, HISTORY_CAP - 1)
        end
      end
    end

    class << self
      # Stable 16-hex lid from (schedule, klass, options). Re-registering
      # the same triple no-ops because the Redis writes overwrite under
      # the same key.
      def lid(schedule, klass, options)
        opts = options.is_a?(Hash) ? options : {}
        ::Digest::SHA1.hexdigest("#{schedule}|#{klass}|#{JSON.dump(opts.sort.to_h)}")[0, 16]
      end

      # Task-stated convenience signature. `name` is treated as a label;
      # the lid is still derived from (schedule, klass, opts) so the
      # call is idempotent. Callers that want the Sidekiq DSL should use
      # `Manager#register` via `config.periodic { |mgr| ... }`.
      def register(name, cron, worker_class, args = [], **opts)
        merged = opts.merge(args: args)
        merged[:label] = name if name
        Loop.new(schedule: cron, klass: worker_class.to_s, options: merged).tap { |lp| persist(lp) }
      end

      def persist(loop_obj)
        Wurk.redis do |c|
          c.call('SADD', PERIODIC_KEY, loop_obj.lid)
          c.call('HSET', "#{LOOP_PREFIX}#{loop_obj.lid}", *loop_obj.to_redis_hash.flatten)
        end
        loop_obj
      end

      # Drop a loop entirely. Used by the Web UI delete action and by the
      # config-reload path so a removed `register(...)` line vanishes from
      # Redis on next boot.
      def unregister(lid)
        Wurk.redis do |c|
          c.call('SREM', PERIODIC_KEY, lid)
          c.call('DEL', "#{LOOP_PREFIX}#{lid}", "#{HISTORY_PREFIX}#{lid}")
        end
      end

      # Test helper: wipe every Cron Redis key. Production code must not
      # call this — it removes every registered loop in the cluster.
      def reset!
        Wurk.redis do |c|
          lids = c.call('SMEMBERS', PERIODIC_KEY)
          lids.each do |lid|
            c.call('DEL', "#{LOOP_PREFIX}#{lid}", "#{HISTORY_PREFIX}#{lid}")
          end
          c.call('DEL', PERIODIC_KEY, LEADER_KEY)
        end
      end

      def jobs
        LoopSet.new
      end
    end
  end

  Periodic = Cron unless const_defined?(:Periodic)
end
