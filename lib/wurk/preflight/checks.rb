# frozen_string_literal: true

require_relative '../boot_checks'
require_relative '../keys'
require_relative 'payload_sample'

module Wurk
  module Preflight
    # The questions a preflight answers, each reading Redis through the Reader
    # and writing to the Report. Run before the cutover, so a live stock fleet is
    # normal here (Verify is the one that expects Wurk).
    class Checks
      MIN_REDIS = ::Gem::Version.new('7.0.0')
      DRAGONFLY_FULL_RATIO = 0.8

      # Add-ons that are known not to work on Wurk, or that must be gone by cutover.
      KNOWN_BROKEN = {
        'sidekiq-pro' => 'licensed gem: remove it, Wurk replaces it',
        'sidekiq-ent' => 'licensed gem: remove it, Wurk replaces it',
        'sidekiq-status' => 'untested on Wurk, and its web tab expects stock ERB rendering; prefer `track:`',
        'sidekiq-throttled' => 'patches stock fetch classes, which Wurk does not use; use Sidekiq::Limiter'
      }.freeze

      def initialize(reader:, report:, keyspace:, owners:, sample:)
        @reader = reader
        @report = report
        @keyspace = keyspace
        @owners = owners
        @sample = sample
      end

      def run
        server
        processes
        scan_coverage
        private_lists
        payloads
        batches
        locks
      end

      def app(specs: ::Gem.loaded_specs)
        add_ons(specs)
        ignored_locks
      end

      private

      def server
        info = parse_info(@reader.call('INFO'))
        name, version = BootChecks.backend(info)
        @report.section('redis', server_section(info, name, version))
        version_check(name, version)
        topology(info)
        eviction(info['maxmemory_policy'], name)
        dragonfly_memory(info) if name == 'dragonfly'
      end

      def server_section(info, name, version)
        { 'backend' => name, 'version' => version, 'mode' => info['redis_mode'], 'role' => info['role'],
          'eviction' => info['maxmemory_policy'], 'used_memory' => info['used_memory'].to_i,
          'maxmemory' => info['maxmemory'].to_i, 'keys' => @reader.call('DBSIZE') }
      end

      def parse_info(text)
        text.each_line.with_object({}) do |line, out|
          key, value = line.strip.split(':', 2)
          out[key] = value if value
        end
      end

      def version_check(name, version)
        return unless name == 'redis' && ::Gem::Version.correct?(version) && ::Gem::Version.new(version) < MIN_REDIS

        @report.warning('redis_version', "Redis #{version} is below the required 7.0.")
      end

      def topology(info)
        return unless info['cluster_enabled'] == '1' || info['redis_mode'] == 'cluster'

        @report.warning('redis_cluster', 'Redis Cluster is not supported: `nodes:` raises. Use standalone or Sentinel.')
      end

      def eviction(policy, name)
        return if policy == 'noeviction'

        if policy.nil?
          @report.info('eviction_unknown', "#{name} does not report maxmemory_policy: confirm it cannot evict keys.")
        else
          @report.warning('eviction', "maxmemory_policy is #{policy}: an evicting policy can silently drop queues.")
        end
      end

      def dragonfly_memory(info)
        used = info['used_memory'].to_f
        max = info['maxmemory'].to_f
        if max.positive? && used / max >= DRAGONFLY_FULL_RATIO
          @report.warning('dragonfly_memory', "Dragonfly is at #{(100 * used / max).round}% of maxmemory. Near the " \
                                              'limit it can drop a job mid-move: see docs/deployment.md.')
        else
          @report.info('dragonfly', 'Dragonfly: keep it well below maxmemory and alert on it. See docs/deployment.md.')
        end
      end

      def processes # rubocop:disable Metrics/AbcSize
        wurk, other = @owners.processes.partition(&:wurk)
        by_version = @owners.processes.group_by { |p| "#{p.wurk ? 'wurk' : 'other'} #{p.version}" }
        @report.section('processes', { 'live' => @owners.processes.size, 'stale_members' => @owners.stale.size,
                                       'by_version' => by_version.transform_values(&:size) })
        return unless wurk.any? && other.any?

        @report.warning('mixed_fleet', "#{other.size} non-Wurk and #{wurk.size} Wurk process(es) share this Redis.")
      end

      def scan_coverage
        @report.section('keyspace', @keyspace.to_h)
        return unless @keyspace.truncated?

        @report.warning('scan_truncated', "Stopped at #{@keyspace.scanned} keys: every count below is a lower bound " \
                                          'and this run cannot call the keyspace clean. Raise --limit.')
      end

      def private_lists
        lists = @owners.classify(@keyspace.private_lists)
        examples = lists.transform_values { |keys| keys.first(10) }
        @report.section('private_lists', lists.transform_values(&:size).merge('samples' => examples))
        name_unparseable(lists['unparseable'])
        return if lists['reclaimable'].empty?

        @report.warning('reclaimable_lists', "#{lists['reclaimable'].size} private list(s) have no live owner. Wurk " \
                                             'reclaims these shapes after its grace; stock Sidekiq never does.')
      end

      def name_unparseable(keys)
        return if keys.empty?

        @report.warning('unparseable_lists', "#{keys.size} key(s) look like private lists in a shape Wurk cannot " \
                                             "read, and it will not reclaim them: #{keys.first(10).join(', ')}. " \
                                             'Inspect them; if their owners are gone, move the jobs back by hand.')
      end

      def payloads
        sampled = PayloadSample.new(@reader, per_source: @sample).take(@owners.queue_names)
        @report.section('payloads', sampled.to_h)
        sampled.report_to(@report, foreign: @owners.foreign.any?)
      end

      def batches # rubocop:disable Metrics/AbcSize
        hashes = batch_hashes
        fields = @reader.pipeline(hashes.map { |key| ['HMGET', key, 'pending', 'callbacks'] })
        in_flight = hashes.zip(fields).select { |_, (pending, _)| pending.to_i.positive? }
        bare = in_flight.reject { |_, (_, callbacks)| callbacks }.map(&:first)
        @report.section('batches', { 'seen' => @keyspace.counts['batches'], 'inspected' => hashes.size,
                                     'in_flight' => in_flight.size, 'without_callbacks' => bare.size })
        return if bare.empty?

        @report.warning('batch_without_callbacks',
                        "#{bare.size} in-flight batch(es) have no `callbacks` field, e.g. #{bare.first}. Wurk finds " \
                        'no callbacks to fire on these: let them finish before the cutover.')
      end

      def batch_hashes
        rows = @keyspace.batches.first(@sample)
        rows.zip(@reader.pipeline(rows.map { |key| ['TYPE', key] })).filter_map { |key, type| key if type == 'hash' }
      end

      def locks
        counts = @keyspace.counts
        @report.section('locks', counts.slice('unique_sha1', 'unique_sha256', 'unique_other', 'gem_locks', 'gem_keys'))
        if counts['unique_sha1'].positive?
          @report.warning('unique_sha1', "#{counts['unique_sha1']} `unique:` lock(s) carry a SHA1-length digest. " \
                                         "Wurk's digest is SHA256, so it does not see them: one duplicate per " \
                                         'identity until their TTL.')
        end
        return unless counts['gem_locks'].positive?

        @report.info('gem_locks', "#{counts['gem_locks']} sidekiq-unique-jobs lock(s). Keep the gem and they carry " \
                                  'over. Drop it and they stay held: UNLINK `uniquejobs:*` before any rollback.')
      end

      def add_ons(specs)
        found = KNOWN_BROKEN.select { |name, _| specs.key?(name) }
        real = specs['sidekiq']
        @report.section('app', { 'gems_seen' => specs.size, 'known_broken' => found.keys })
        found.each { |name, why| @report.warning('known_broken_gem', "#{name}: #{why}.") }
        return unless real && !real.full_gem_path.include?('sidekiq-shim')

        @report.warning('real_sidekiq_gem', "The bundle holds a released sidekiq #{real.version}: it would load next " \
                                            'to Wurk. Use the shim gem. See docs/migrate-from-sidekiq.md.')
      end

      def ignored_locks
        return if defined?(::SidekiqUniqueJobs)

        classes = BootChecks.locked_job_classes
        return if classes.empty?

        @report.warning('ignored_lock', "#{classes.size} class(es) set `lock:` with sidekiq-unique-jobs not loaded, " \
                                        "so duplicates run: #{BootChecks.listing(classes)}.")
      end
    end
  end
end
