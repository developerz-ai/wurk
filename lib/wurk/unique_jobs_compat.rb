# frozen_string_literal: true

require_relative 'keys'

module Wurk
  # Two corrections to sidekiq-unique-jobs, applied when a server boots with the
  # gem loaded. The gem cannot see what only the reliable fetcher knows.
  module UniqueJobsCompat
    # Same MATCH the fetcher's Reaper uses: Wurk's and Sidekiq Pro's private lists.
    PRIVATE_LISTS = "#{Keys::QUEUE_PREFIX}*|*".freeze
    SCAN_COUNT = 1000
    RUN_SUFFIX = ':RUN'
    OOM = /\AOOM\b|\bout of memory\b/i
    VERSION_KEY = 'uniquejobs:live'

    # RubyReaper reads public queues, the retry and schedule sets and live
    # workers. A job in a dead worker's private list is in none of them until it
    # is reclaimed, so its lock read as orphaned and was deleted, and a duplicate
    # ran beside the recovery. The list names are kept for the run (a list
    # created later has a live owner), the payloads are read per digest, because
    # a job may have moved since the last look.
    module PrivateListsAreLive
      def belongs_to_job?(digest)
        super || in_private_list?(digest)
      end

      private

      def in_private_list?(digest)
        lists = (@wurk_private_lists ||= wurk_scan_private_lists)
        return false if lists.empty?

        base = digest.delete_suffix(RUN_SUFFIX)
        replies = Wurk.redis { |c| c.pipelined { |p| lists.each { |list| p.call('LRANGE', list, 0, -1) } } }
        replies.any? { |payloads| payloads.is_a?(::Array) && payloads.any? { |job| job.include?(base) } }
      end

      def wurk_scan_private_lists
        cursor = '0'
        lists = []
        loop do
          cursor, keys = Wurk.redis do |c|
            c.call('SCAN', cursor, 'MATCH', PRIVATE_LISTS, 'COUNT', SCAN_COUNT, 'TYPE', 'list')
          end
          lists.concat(keys)
          break if cursor == '0'
        end
        lists.uniq
      end
    end

    # The gem writes its version at boot, for upgrades it has not built yet, and
    # a refusal there stops the worker. At `maxmemory` that is a crash loop with
    # nothing draining the queues. Only this write is forgiven: a lock write
    # refused by OOM still raises.
    module VersionWriteIsOptional
      def call
        super
      rescue StandardError => e # the gem wraps a script's error in its own class
        raise unless OOM.match?(e.message.to_s)

        Wurk.logger.error do
          "sidekiq-unique-jobs: Redis is at maxmemory, so #{VERSION_KEY} was not set to " \
            "#{UniqueJobsCompat.gem_version}. Booting anyway; locks are unaffected. (#{e.message})"
        end
        false
      end
    end

    class << self
      def install
        return unless defined?(::SidekiqUniqueJobs::Orphans::RubyReaper) && defined?(::SidekiqUniqueJobs::UpdateVersion)

        ::SidekiqUniqueJobs::Orphans::RubyReaper.prepend(PrivateListsAreLive)
        ::SidekiqUniqueJobs::UpdateVersion.singleton_class.prepend(VersionWriteIsOptional)
        true
      end

      def gem_version
        defined?(::SidekiqUniqueJobs::VERSION) ? ::SidekiqUniqueJobs::VERSION : 'unknown'
      end
    end
  end
end
