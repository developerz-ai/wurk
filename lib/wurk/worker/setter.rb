# frozen_string_literal: true

require 'date'
require_relative '../job_util'

module Wurk
  module Worker
    # Aliased as `Sidekiq::Job::Setter`. Per-call option carrier returned
    # by `Worker.set(opts)`. Holds string-keyed overrides and exposes the
    # same `perform_*` surface as the worker class itself.
    #
    # `set(sync: true)` makes `perform_async` invoke `perform_inline` —
    # required for testing-mode parity.
    #
    # Spec: docs/target/sidekiq-free.md §6.3 (Sidekiq::Job::Setter).
    class Setter
      include Wurk::JobUtil

      def initialize(klass, opts)
        @klass = klass
        @opts = normalize_opts(opts)
      end

      def set(options)
        @opts.merge!(normalize_opts(options))
        self
      end

      def perform_async(*args)
        return perform_inline(*args) if @opts['sync']

        @klass.client_push(@opts.merge('class' => @klass, 'args' => args))
      end

      # Explicit synchronous execution. Runs the payload through the real client
      # AND server middleware chains rather than calling `perform` directly:
      # unique-job locks are taken by the client chain and released only by the
      # server chain (bypassing both leaked every lock until its TTL), and batch
      # callbacks fire from server middleware. Mirrors Sidekiq's Setter#perform_inline,
      # including its return contract — nil when middleware halts the job, else true.
      def perform_inline(*args)
        config = Wurk.configuration
        item = normalize_item(@opts.merge('class' => @klass, 'args' => args))
        pushed = config.client_middleware.invoke(item['class'], item, item['queue'], config.redis_pool) do
          verify_json(item)
          item
        end
        return nil unless pushed

        # Round-trip through JSON so the job sees exactly the arguments a real
        # worker would after the payload has crossed Redis.
        run_job(Wurk.load_json(Wurk.dump_json(item)), config)
      end
      alias perform_sync perform_inline

      def perform_in(interval, *args)
        ts = absolute_at(interval)
        item = @opts.merge('class' => @klass, 'args' => args)
        item['at'] = ts if ts && ts > now_seconds
        @klass.client_push(item)
      end
      alias perform_at perform_in

      def perform_bulk(args, **opts)
        merged = @opts.merge(opts.transform_keys(&:to_s)).merge(
          'class' => @klass,
          'args' => args
        )
        # Mirror client_push: a per-call `set(pool:)` selects the Redis pool and
        # is removed so it never persists (normalize_item strips the class-level
        # pool re-merged into each payload).
        pool = merged.delete('pool') || @klass.get_sidekiq_options['pool']
        @klass.build_client(pool).push_bulk(merged)
      end

      private

      def run_job(msg, config)
        instance = @klass.new
        instance.jid = msg['jid']
        instance.bid = msg['bid'] if instance.respond_to?(:bid=)
        ran = config.server_middleware.invoke(instance, msg, msg['queue']) do
          instance.perform(*msg['args'])
          true
        end
        ran ? true : nil
      end

      # Sidekiq's `Setter#at` rule, shared by `perform_in`/`perform_at` and
      # `set(wait:)`/`set(wait_until:)`: a number below 1e9 is seconds from now,
      # anything at or above it is already an epoch timestamp. A Date/DateTime
      # is converted through #to_time — stock Ruby gives DateTime no #to_f.
      # Strings are refused rather than read through #to_f, where `"soon"`
      # would silently mean "now".
      def absolute_at(interval)
        seconds = interval_seconds(interval)
        seconds < Wurk::Worker::SCHEDULED_THRESHOLD ? now_seconds + seconds : seconds
      end

      def interval_seconds(interval)
        case interval
        when Numeric, Time then interval.to_f
        when Date then interval.to_time.to_f
        else raise ArgumentError, "interval must be Numeric, Time or DateTime, got #{interval.class}"
        end
      end

      def now_seconds
        ::Process.clock_gettime(::Process::CLOCK_REALTIME)
      end

      # Lifts wait/wait_until → at; stringifies keys. Matches Sidekiq's
      # Setter initializer normalization exactly.
      def normalize_opts(opts)
        result = {}
        opts.each do |k, v|
          key = k.to_s
          case key
          when 'wait', 'wait_until'
            # Sidekiq drops `at` when the target is not in the future, so
            # set(wait: 0) / an elapsed wait_until enqueues immediately
            # instead of parking in the schedule ZSET for up to a poll tick.
            ts = absolute_at(v)
            result['at'] = ts if ts > now_seconds
          else result[key] = v
          end
        end
        result
      end
    end
  end
end
