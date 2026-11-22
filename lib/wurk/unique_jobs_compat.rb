# frozen_string_literal: true

require_relative 'keys'
require_relative 'unique_jobs_compat/private_list_digests'

module Wurk
  # Two corrections to sidekiq-unique-jobs, applied when a server boots with the
  # gem loaded. The gem cannot see what only the reliable fetcher knows.
  module UniqueJobsCompat
    RUN_SUFFIX = ':RUN'
    OOM = /\AOOM\b|\bout of memory\b/i
    VERSION_KEY = 'uniquejobs:live'

    # RubyReaper reads public queues, the retry and schedule sets and live
    # workers. A job in a dead worker's private list is in none of them until it
    # is reclaimed, so its lock read as orphaned and was deleted, and a duplicate
    # ran beside the recovery.
    #
    # The lists are read once before the gem classifies its digests and once
    # after, so a run costs O(digests + jobs). Both reads are needed: a job
    # fetched after the gem looked at its public queue is only in the second, and
    # one reclaimed back to its queue after that look is only in the first. A
    # failed read raises here, ahead of the gem's delete.
    module PrivateListsAreLive
      def orphans
        before = PrivateListDigests.new.call
        candidates = super
        after = PrivateListDigests.new.call
        UniqueJobsCompat.report_unreadable([before.unreadable, after.unreadable].max)
        candidates.reject do |digest|
          base = digest.delete_suffix(RUN_SUFFIX)
          before.digests.include?(base) || after.digests.include?(base)
        end
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

        guard_reaper(::SidekiqUniqueJobs::Orphans::RubyReaper)
        ::SidekiqUniqueJobs::UpdateVersion.singleton_class.prepend(VersionWriteIsOptional)
        true
      end

      def guard_reaper(reaper)
        return reaper.prepend(PrivateListsAreLive) if reaper.method_defined?(:orphans)

        Wurk.logger.error do
          "sidekiq-unique-jobs #{gem_version} has no RubyReaper#orphans, so its reaper can delete the lock of a " \
            'job in a private list. Set `config.reaper = :none` or use a supported version.'
        end
      end

      def report_unreadable(count)
        return unless count.positive?

        Wurk.logger.warn do
          "sidekiq-unique-jobs reaper: #{count} unreadable payload(s) in private lists; " \
            'every lock they name was kept.'
        end
      end

      def gem_version
        defined?(::SidekiqUniqueJobs::VERSION) ? ::SidekiqUniqueJobs::VERSION : 'unknown'
      end
    end
  end
end
