# frozen_string_literal: true

module Wurk
  module Preflight
    # `wurk preflight --app` rows read from the app's source and bundle, not from
    # Redis: the patterns that carried over from stock Sidekiq and behave
    # differently on Wurk. A text scan, so a row is a place to look, not a verdict.
    class AppScan
      SOURCE_DIRS = %w[app lib config].freeze
      MAX_SITES = 20

      # Sidekiq 8 and Wurk store these as epoch milliseconds; Sidekiq 7 stored
      # float seconds, and code written against it reads them that way.
      TIME_FIELD_READ = /\[['"](?:failed_at|created_at|enqueued_at|retried_at)['"]\]/
      FLUSH = /\b(?:flushdb|flushall)\b/i
      PRO_ENT_GUARD = /defined\?\(\s*(?:::)?Sidekiq::(?:Pro|Enterprise|Ent)\b|Sidekiq\.(?:pro|ent)\?/
      RUNNER_COMMAND = /\b(?:wurk|wurkswarm|sidekiq|sidekiqswarm)\b/
      WEB_SERVER_COMMAND = /\brails\s+(?:s|server)\b|\bpuma\b/
      PROCFILES = %w[Procfile Procfile.dev].freeze

      # The upstream versions each plugin's own suite runs green against Wurk
      # (`ref:` in test/ecosystem/<gem>/PIN, which preflight_app_scan_test.rb
      # holds this to).
      TESTED_PLUGINS = {
        'sentry-sidekiq' => '6.5.0',
        'sidekiq-cron' => '2.4.0',
        'sidekiq-failures' => '1.1.0',
        'sidekiq-unique-jobs' => '8.1.0'
      }.freeze

      def initialize(root:, report:, specs: ::Gem.loaded_specs)
        @root = root
        @report = report
        @specs = specs
      end

      def run
        time_fields
        connection_pool_pin
        rails_error_subscribers
        web_also_runs_workers
        flush_at_boot
        plugin_versions
        pro_ent_guards
      end

      private

      def time_fields
        sites = grep(SOURCE_DIRS, TIME_FIELD_READ)
        return if sites.empty?

        @report.info('time_field_read',
                     "#{sites.size} place(s) read failed_at, created_at, enqueued_at or retried_at off a job. Wurk " \
                     'stores them as epoch milliseconds, as Sidekiq 8 does; code that reads seconds is off by 1000x: ' \
                     "#{listing(sites)}.")
      end

      def connection_pool_pin
        needed = wurk_requirement('connection_pool')
        return unless needed

        locked = locked_version('connection_pool')
        return pin_unreadable(needed) unless locked
        return if needed.satisfied_by?(locked)

        @report.warning('connection_pool_pin', "Gemfile.lock holds connection_pool #{locked}; Wurk needs #{needed}" \
                                               "#{gemfile_pin('connection_pool')}. Relax the pin before the swap.")
      end

      def pin_unreadable(needed)
        @report.info('connection_pool_pin',
                     "No Gemfile.lock under #{@root}. Wurk needs connection_pool #{needed}; check the bundle's with " \
                     "`bundle exec ruby -e 'puts Gem.loaded_specs[%(connection_pool)].version'`.")
      end

      # Jobs run inside the Rails reloader, and what raises there crosses
      # Rails.error, so a subscriber may see an error on every attempt.
      def rails_error_subscribers
        reporter = defined?(::Rails) && ::Rails.respond_to?(:error) && ::Rails.error
        subscribers = reporter ? Array(reporter.instance_variable_get(:@subscribers)) : []
        return if subscribers.empty?

        names = subscribers.map { |sub| sub.is_a?(::Module) ? sub.name : sub.class.name }.uniq
        @report.info('rails_error_subscriber',
                     "Rails.error has #{subscribers.size} subscriber(s): #{listing(names)}. Jobs run inside the " \
                     'Rails reloader, so a subscriber may see a job error on every attempt, not only the last. ' \
                     'See docs/sentry.md.')
      end

      # Under a Rails web server Wurk boots workers in the web process too, so a
      # Procfile that also starts a worker runs two, and boot code that flushes
      # Redis runs in each.
      def web_also_runs_workers
        PROCFILES.each do |name|
          entries = procfile(name)
          web = entries['web']
          next unless web && !web.include?('WURK_DISABLED=1') && WEB_SERVER_COMMAND.match?(web)
          next unless entries.any? { |process, command| process != 'web' && RUNNER_COMMAND.match?(command) }

          @report.warning('web_would_embed', "#{name} starts a worker, and its web process would boot workers too. " \
                                             'Set WURK_DISABLED=1 on the web entry (or wherever its env is set).')
        end
      end

      def flush_at_boot
        sites = grep(%w[config], FLUSH)
        return if sites.empty?

        @report.warning('flush_at_boot', 'Boot code flushes Redis, and a Wurk worker runs it in every process it ' \
                                         "boots (every swarm child): #{listing(sites)}. Remove it, or scope it to " \
                                         'one place that runs once.')
      end

      def plugin_versions
        TESTED_PLUGINS.each do |name, tested|
          spec = @specs[name]
          next if spec.nil? || spec.version.to_s == tested

          @report.info('plugin_version', "#{name} #{spec.version} is bundled; its suite runs green against Wurk at " \
                                         "#{tested}. Pin #{tested}, or run that version's suite before the swap.")
        end
      end

      def pro_ent_guards
        sites = grep(SOURCE_DIRS, PRO_ENT_GUARD)
        return if sites.empty?

        @report.info('pro_ent_guard', "#{sites.size} branch(es) test for Sidekiq Pro or Enterprise. Under Wurk the " \
                                      '`Sidekiq::Pro` and `Sidekiq::Enterprise` namespaces exist but hold only what ' \
                                      'Wurk aliases, and `Sidekiq.pro?` and `.ent?` return false: check which ' \
                                      "branch each one now takes: #{listing(sites)}.")
      end

      def grep(dirs, pattern)
        dirs.flat_map { |dir| ::Dir.glob(::File.join(@root, dir, '**', '*.rb')).sort }.flat_map do |path|
          ::File.foreach(path).with_index(1).filter_map do |line, number|
            "#{relative(path)}:#{number}" if pattern.match?(line.scrub)
          end
        end
      end

      def procfile(name)
        path = ::File.join(@root, name)
        return {} unless ::File.file?(path)

        ::File.foreach(path).each_with_object({}) do |line, out|
          process, command = line.split(':', 2)
          out[process.strip] = command.strip if command && !process.strip.start_with?('#')
        end
      end

      def wurk_requirement(name)
        dependency = @specs['wurk']&.dependencies&.find { |dep| dep.name == name }
        dependency&.requirement
      end

      def locked_version(name)
        lockfile = ::File.join(@root, 'Gemfile.lock')
        return unless ::File.file?(lockfile)

        version = ::File.read(lockfile)[/^ {4}#{::Regexp.escape(name)} \(([^)]+)\)$/, 1]
        ::Gem::Version.new(version) if version && ::Gem::Version.correct?(version)
      end

      def gemfile_pin(name)
        gemfile = ::File.join(@root, 'Gemfile')
        return '' unless ::File.file?(gemfile)

        number = ::File.foreach(gemfile).with_index(1).find { |line, _| line.match?(/^\s*gem\s+['"]#{name}['"]/) }&.last
        number ? ", and Gemfile:#{number} pins it" : ''
      end

      def relative(path) = path.delete_prefix("#{@root}/")

      def listing(sites)
        extra = sites.size - MAX_SITES
        sites.first(MAX_SITES).join(', ') + (extra.positive? ? " and #{extra} more" : '')
      end
    end
  end
end
