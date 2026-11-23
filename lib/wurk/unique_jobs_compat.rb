# frozen_string_literal: true

require_relative 'keys'
require_relative 'unique_jobs_compat/private_list_digests'

module Wurk
  # sidekiq-unique-jobs, either way: Wurk's native copy of it (Wurk::UniqueJobs,
  # answering to `SidekiqUniqueJobs` when the gem is not in the bundle), and two
  # corrections to the gem itself, applied when a server boots with the gem
  # loaded. The gem cannot see what only the reliable fetcher knows.
  module UniqueJobsCompat
    GEM = 'sidekiq-unique-jobs'
    RUN_SUFFIX = ':RUN'
    # Holds `sidekiq_unique_jobs.rb`, `sidekiq-unique-jobs.rb` and the gem's
    # other entry points, so an app's `require` of them loads the native copy.
    REQUIRE_PATH = File.expand_path('unique_jobs/require', __dir__)
    # The client middleware of either copy, by name, so neither is loaded to ask.
    CLIENT_MIDDLEWARE = %w[SidekiqUniqueJobs::Middleware::Client Wurk::UniqueJobs::Middleware::Client].freeze
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
      # The gem in the bundle (or already loaded) owns `SidekiqUniqueJobs` and its
      # require paths; without it the native copy takes both. The path goes last
      # on $LOAD_PATH, so it never shadows a gem installed later.
      # Returns which copy owns the name: :gem or :native.
      def activate_native
        LazyLoader.register(Wurk, UniqueJobs: 'unique_jobs') unless Wurk.const_defined?(:UniqueJobs, false)
        return :gem if gem_present?

        ::Object.autoload(:SidekiqUniqueJobs, File.expand_path('unique_jobs/sidekiq_unique_jobs', __dir__))
        $LOAD_PATH.push(REQUIRE_PATH) unless $LOAD_PATH.include?(REQUIRE_PATH)
        :native
      end

      def gem_present?
        return true if ::Gem.loaded_specs.key?(GEM)

        defined?(::SidekiqUniqueJobs) == 'constant' && ::Object.autoload?(:SidekiqUniqueJobs).nil? &&
          !(defined?(::Wurk::UniqueJobs) && ::SidekiqUniqueJobs.equal?(::Wurk::UniqueJobs))
      end

      # Whether a chain runs either copy's client middleware.
      def client_middleware?(chain) = chain.any? { |entry| CLIENT_MIDDLEWARE.include?(entry.klass.name) }

      # The Locksmith of whichever copy is live: the gem's when it is loaded, else
      # the native one. nil when the gem is in the bundle but not yet required.
      def locksmith_class
        return ::Wurk::UniqueJobs::Locksmith unless gem_present?

        ::SidekiqUniqueJobs::Locksmith if defined?(::SidekiqUniqueJobs::Locksmith)
      end

      def install
        # Asked first: `defined?(::SidekiqUniqueJobs::…)` would load the native copy.
        return unless gem_present?
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
        gem_present? && defined?(::SidekiqUniqueJobs::VERSION) ? ::SidekiqUniqueJobs::VERSION : 'unknown'
      end
    end
  end
end
