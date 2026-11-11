# frozen_string_literal: true

require 'json'
require_relative '../keys'

module Wurk
  module Preflight
    # A bounded look at stored payloads: the oldest and newest entries of every
    # queue and sorted set. Reports shapes and jids, never arguments.
    class PayloadSample
      TIME_FIELDS = %w[created_at enqueued_at failed_at retried_at].freeze
      # Same line Wurk's own readers draw between float seconds and integer ms.
      MILLIS_FROM = 10_000_000_000
      MAX_EXAMPLES = 5

      def initialize(reader, per_source:)
        @reader = reader
        @half = [per_source / 2, 1].max
        @stats = { 'sampled' => 0, 'unparseable' => 0, 'seconds' => 0, 'millis' => 0, 'retry_for' => 0,
                   'sealed' => 0, 'encrypt_without_envelope' => 0 }
        @examples = []
      end

      def take(queue_names)
        queue_names.each { |name| read_list("#{Keys::QUEUE_PREFIX}#{name}") }
        [Keys::RETRY, Keys::SCHEDULE, Keys::DEAD].each { |set| read_set(set) }
        self
      end

      def to_h = @stats.merge('encrypt_examples' => @examples)

      def report_to(report, foreign:)
        report_timestamps(report, foreign)
        report_retry_for(report)
        report_encryption(report)
      end

      private

      def read_list(key)
        ranges = [[0, @half - 1], [-@half, -1]].map { |from, to| ['LRANGE', key, from, to] }
        @reader.pipeline(ranges).flatten.uniq.each { |raw| observe(raw) }
      end

      def read_set(key)
        ranges = [[0, @half - 1], [-@half, -1]].map { |from, to| ['ZRANGE', key, from, to] }
        @reader.pipeline(ranges).flatten.uniq.each { |raw| observe(raw) }
      end

      def observe(raw)
        job = ::JSON.parse(raw)
        return @stats['unparseable'] += 1 unless job.is_a?(::Hash)

        @stats['sampled'] += 1
        TIME_FIELDS.each { |field| tally_time(job[field]) }
        @stats['retry_for'] += 1 if job['retry_for']
        tally_encryption(job)
      rescue ::JSON::ParserError
        @stats['unparseable'] += 1
      end

      def tally_time(value)
        return unless value.is_a?(::Numeric)

        @stats[value.is_a?(::Integer) && value >= MILLIS_FROM ? 'millis' : 'seconds'] += 1
      end

      def tally_encryption(job)
        return unless job['encrypt']

        args = job['args']
        return unless args.is_a?(::Array) && !args.empty?
        return @stats['sealed'] += 1 if Wurk::Encryption.envelope?(args.last)

        @stats['encrypt_without_envelope'] += 1
        @examples << { 'class' => job['class'], 'jid' => job['jid'] } if @examples.size < MAX_EXAMPLES
      end

      def report_timestamps(report, foreign)
        return unless foreign && @stats['millis'].positive?

        report.warning('millis_timestamps', "#{@stats['millis']} sampled timestamp(s) are integer milliseconds while " \
                                            'non-Wurk processes are live. Sidekiq 7.x reads them as seconds: ' \
                                            'negative latency, and `retry_for` never expires.')
      end

      def report_retry_for(report)
        return unless @stats['retry_for'].positive?

        report.info('retry_for', "#{@stats['retry_for']} sampled job(s) set `retry_for`. After Wurk has run them, " \
                                 'a rollback to Sidekiq 7.x ignores it on any job Wurk failed first.')
      end

      def report_encryption(report)
        if @stats['encrypt_without_envelope'].positive?
          report.warning('encrypt_without_envelope',
                         "#{@stats['encrypt_without_envelope']} sampled job(s) have `encrypt` set and a last " \
                         'argument that is no Wurk envelope. With crypto on, Wurk sends these to the dead set unrun.')
        end
        return unless @stats['sealed'].positive?

        report.info('sealed_payloads',
                    "#{@stats['sealed']} sampled job(s) hold Wurk envelopes, which only Wurk can open.")
      end
    end
  end
end
