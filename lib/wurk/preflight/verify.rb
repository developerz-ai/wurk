# frozen_string_literal: true

require_relative '../client'
require_relative '../keys'
require_relative '../preflight'
require_relative 'keyspace'
require_relative 'owners'
require_relative 'reader'
require_relative 'report'

module Wurk
  module Preflight
    # `wurk verify`: the post-cutover check. Read-only, unless `canary:` names a
    # job class to push to every subscribed queue. Run it again after a few
    # minutes rather than trusting one pass: lists of a just-stopped fleet and a
    # leader election are both normal in the first ~2 minutes.
    class Verify
      def self.run(config, canary: nil, limit: Preflight::DEFAULT_LIMIT, pause: 0.005, progress: nil, now: ::Time.now)
        reader = Reader.new(config)
        report = Report.new('verify')
        keyspace = Keyspace.new(reader, limit: limit, pause: pause, progress: progress).walk
        report.target(reader, keyspace)
        new(reader, report, keyspace, Owners.new(reader), now).run
        push_canaries(config, report, canary, Owners.new(reader)) if canary
        report
      ensure
        reader&.close
      end

      def self.push_canaries(config, report, klass, owners)
        queues = owners.processes.flat_map(&:queues).uniq.sort
        client = Wurk::Client.new(config: config)
        jids = queues.to_h { |queue| [queue, client.push('class' => klass, 'queue' => queue, 'args' => [queue])] }
        report.section('canary', { 'class' => klass, 'pushed' => jids })
        report.info('canary', "Pushed #{klass} to #{jids.size} queue(s). This says the push worked: confirm each ran " \
                              'in your logs.')
      end

      def initialize(reader, report, keyspace, owners, now)
        @reader = reader
        @report = report
        @keyspace = keyspace
        @owners = owners
        @now = now
      end

      def run
        processes
        queues
        private_lists
        leader
        cron
      end

      private

      def processes
        foreign = @owners.foreign.map(&:identity)
        @report.section('processes', { 'live' => @owners.processes.size, 'non_wurk' => foreign })
        @report.warning('no_processes', 'No live worker processes.') if @owners.processes.empty?
        return if foreign.empty?

        @report.warning('non_wurk_process', "Non-Wurk processes still live: #{foreign.first(10).join(', ')}.")
      end

      def queues
        names = @owners.queue_names
        subscribed = @owners.processes.flat_map(&:queues).tally
        paused = @reader.call('SMEMBERS', Keys::PAUSED_SET)
        unconsumed = unconsumed_with_jobs(names - subscribed.keys - paused)
        @report.section('queues', { 'known' => names.size, 'subscribed' => subscribed, 'paused' => paused,
                                    'unconsumed_with_jobs' => unconsumed })
        return if unconsumed.empty?

        @report.warning('queue_unconsumed', "No live process subscribes to: #{unconsumed.first(20).join(', ')}. " \
                                            'These jobs wait with no error.')
      end

      def unconsumed_with_jobs(names)
        heads = @reader.pipeline(names.map { |name| ['LINDEX', "#{Keys::QUEUE_PREFIX}#{name}", 0] })
        names.zip(heads).select { |_, head| head }.map(&:first)
      end

      # A process holds at most one private list per queue it serves.
      def private_lists
        lists = @owners.classify(@keyspace.private_lists)
        expected = @owners.processes.sum { |p| p.queues.size }
        @report.section('private_lists', lists.transform_values(&:size).merge('expected_at_most' => expected))
        reclaimable(lists['reclaimable'])
        unparseable(lists['unparseable'])
        too_many(lists['owner_alive'].size, expected)
      end

      def too_many(found, expected)
        return if found <= expected

        @report.warning('private_list_count', "#{found} live-owned private lists, above the #{expected} this fleet " \
                                              'should hold.')
      end

      def reclaimable(keys)
        return if keys.empty?

        @report.warning('reclaimable_lists', "#{keys.size} private list(s) have no live owner. A Wurk worker " \
                                             'reclaims them within about 2.5 minutes: run this again, and look if ' \
                                             'they stay.')
      end

      def unparseable(keys)
        return if keys.empty?

        @report.warning('unparseable_lists', "#{keys.size} key(s) in a shape Wurk will not reclaim: " \
                                             "#{keys.first(10).join(', ')}. Move their jobs back by hand.")
      end

      def leader
        holder = @reader.call('GET', Leader::DEFAULT_KEY)
        process = @owners.processes.find { |p| p.identity == holder }
        @report.section('leader', { 'holder' => holder, 'live' => !process.nil?, 'wurk' => process&.wurk })
        return @report.warning('no_leader', 'Nothing holds the leader lock: no periodic job fires.') unless holder
        return if process&.wurk

        @report.warning('leader_not_live_wurk', "The leader lock is held by #{holder}, not a live Wurk process.")
      end

      def cron # rubocop:disable Metrics/AbcSize
        lids = @reader.call('SMEMBERS', Cron::PERIODIC_KEY)
        rows = @reader.pipeline(lids.map { |lid| ['HGETALL', "#{Cron::LOOP_PREFIX}#{lid}"] })
        missing = lids.zip(rows).reject { |_, row| row['paused'] == '1' || next_fire(row) }.map(&:first)
        entries = @keyspace.counts['cron_entries']
        @report.section('cron', { 'loops' => lids.size, 'without_next_fire' => missing, 'gem_entries' => entries })
        no_next_fire(missing)
        gem_entries_unfired(entries) if lids.empty?
      end

      def no_next_fire(lids)
        return if lids.empty?

        @report.warning('loop_no_next_fire', "#{lids.size} loop(s) have no next fire: #{lids.first(10).join(', ')}.")
      end

      def gem_entries_unfired(entries)
        return unless entries.positive? && !::Gem.loaded_specs.key?('sidekiq-cron')

        @report.warning('cron_not_moved', "#{entries} sidekiq-cron entries, no native loops, and this bundle has no " \
                                          'sidekiq-cron: if the workers run this bundle, nothing fires them.')
      end

      def next_fire(row)
        return nil if row.empty?

        tz = row['tz'].to_s.empty? ? nil : row['tz']
        Cron::Parser.new(row['schedule']).next_fire_at(@now.to_i, tz)
      rescue ArgumentError
        nil
      end
    end
  end
end
