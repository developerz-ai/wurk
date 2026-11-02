# frozen_string_literal: true

require 'json'
require_relative 'component'
require_relative 'keys'
require_relative 'timer_loop'

module Wurk
  # Who listens to which queue, read from what every process already publishes:
  # the `queues` list in its heartbeat `info`. That list is the union across a
  # process's capsules, so a queue served by one capsule counts. Expired
  # identities have no `info` and are not counted. No new Redis keys.
  module QueueConsumers
    module_function

    # `{ queue => live subscribers }`. A quiet process still counts: it is a
    # deliberate pause, not a queue nobody thought to list.
    def counts(conn)
      ids = conn.call('SMEMBERS', Keys::PROCESSES)
      return {} if ids.empty?

      tally(conn.pipelined { |pipe| ids.each { |id| pipe.call('HGET', id, 'info') } })
    end

    def tally(infos)
      infos.each_with_object(Hash.new(0)) do |info, out|
        subscribed(info).each { |queue| out[queue] += 1 }
      end
    end

    def subscribed(info)
      return [] if info.nil?

      Array(::JSON.parse(info)['queues']).map(&:to_s).uniq
    rescue ::JSON::ParserError, ::TypeError
      []
    end

    # Warns about non-empty queues no live process subscribes to: such jobs wait
    # forever with no error, retry or report. Leader only, one tick a minute.
    #
    # A queue is reported only after `grace` seconds unconsumed on every tick. A
    # rolling restart or a deploy that adds a queue passes through that state
    # briefly, and one leader's in-memory clock is enough to ride it out. A
    # leader change restarts the clock, which only delays a warning.
    class Watch
      include Component

      TICK = 60
      GRACE = 300
      THROTTLE = 3600

      attr_reader :config

      def initialize(config, tick: TICK, grace: GRACE, throttle: THROTTLE,
                     clock: -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) })
        @config = config
        @grace = grace
        @throttle = throttle
        @clock = clock
        @timer = TimerLoop.new(tick)
        @unconsumed_since = {}
        @warned_at = {}
        @thread = nil
      end

      def start
        return @thread if @thread

        @timer.reset
        @thread = safe_thread('queue-consumers') { @timer.run { tick } }
      end

      def terminate
        @timer.terminate
        @thread = nil if @thread&.join(TimerLoop::JOIN_TIMEOUT)
      end

      def tick
        return unless leader?

        check
      rescue StandardError => e
        handle_exception(e, { context: 'queue-consumers' })
      end

      # One pass, bypassing the leader gate. Returns the queues warned about.
      def check
        now = @clock.call
        unconsumed = read_unconsumed
        @unconsumed_since.select! { |queue, _| unconsumed.key?(queue) }
        unconsumed.filter_map do |queue, size|
          @unconsumed_since[queue] ||= now
          next unless warn_due?(queue, now)

          @warned_at[queue] = now
          logger.warn { warning(queue, size) }
          queue
        end
      end

      private

      def warn_due?(queue, now)
        return false if now - @unconsumed_since[queue] < @grace

        at = @warned_at[queue]
        at.nil? || now - at >= @throttle
      end

      def warning(queue, size)
        "Queue #{queue.inspect} has #{size} jobs and no live process subscribes to it, so they will wait " \
          'forever. Add it to the worker\'s queues (or drain it if it is obsolete).'
      end

      def read_unconsumed
        @config.redis(idempotent: true) do |conn|
          counts = QueueConsumers.counts(conn)
          # An empty fleet is a different alarm, and one every monitor already has.
          next {} if counts.empty?

          non_empty(conn, conn.call('SMEMBERS', Keys::QUEUES_SET).reject { |queue| counts.key?(queue) })
        end
      end

      def non_empty(conn, names)
        return {} if names.empty?

        sizes = conn.pipelined { |pipe| names.each { |queue| pipe.call('LLEN', Keys.queue(queue)) } }
        names.zip(sizes).select { |_, size| size.positive? }.to_h
      end
    end
  end
end
