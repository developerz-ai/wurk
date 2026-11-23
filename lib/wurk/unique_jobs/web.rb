# frozen_string_literal: true

require 'cgi'
require 'time'

module Wurk
  module UniqueJobs
    # The gem's Locks, Expiring Locks and Changelogs tabs, on Wurk's dashboard
    # through its extension renderer: `require "sidekiq_unique_jobs/web"`, as
    # with the gem. Same routes, same pages. The views are the gem's, MIT
    # licensed (Copyright (c) 2017 Mikael Henriksson), with every value escaped.
    module Web
      VIEWS = File.expand_path('web/views', __dir__)
      TABS = ['Locks', 'Expiring Locks', 'Changelogs'].freeze
      INDEX = %w[locks/ expiring_locks/ changelogs/].freeze

      # Adds the tabs to a dashboard config, under the gem's extension name.
      def self.register(config, name: 'unique_jobs')
        config.register_extension(self, name: name, tab: TABS, index: INDEX)
      end

      def self.registered(app)
        app.helpers Helpers
        changelog_routes(app)
        list_routes(app)
        delete_routes(app)
        lock_routes(app)
      end

      def self.changelog_routes(app)
        app.get('/changelogs') do
          page_params
          @total_size, @next_cursor, @changelogs = changelog.page(cursor: @current_cursor, pattern: @filter,
                                                                  page_size: @count)
          erb(unique_template(:changelogs))
        end

        app.get('/changelogs/delete_all') do
          changelog.clear
          redirect "#{root_path}changelogs"
        end
      end

      def self.list_routes(app)
        app.get('/locks') do
          page_params
          @total_size, @next_cursor, @locks = digests.page(cursor: @current_cursor, pattern: @filter, page_size: @count)
          erb(unique_template(:locks))
        end

        app.get('/expiring_locks') do
          page_params
          @total_size, @next_cursor, @locks = expiring_digests.page(cursor: @current_cursor, pattern: @filter,
                                                                    page_size: @count)
          erb(unique_template(:locks))
        end
      end

      def self.delete_routes(app)
        app.get('/locks/delete_all') do
          delete_all_locks
          redirect "#{root_path}locks"
        end

        app.get('/locks/:digest/delete') do
          delete_lock(route_params(:digest))
          redirect "#{root_path}locks"
        end
      end

      def self.lock_routes(app)
        app.get('/locks/:digest') do
          @lock = Lock.new(route_params(:digest))
          erb(unique_template(:lock))
        end

        app.get('/locks/:digest/jobs/:job_id/delete') do
          @lock = Lock.new(route_params(:digest))
          @lock.unlock(route_params(:job_id))
          redirect "#{root_path}locks/#{@lock.key}"
        end
      end

      module Helpers
        SAFE_CPARAMS = %w[filter count cursor prev_cursor poll direction].freeze

        def delete_all_locks
          digests.delete_by_pattern('*', count: digests.count)
          expiring_digests.delete_by_pattern('*', count: expiring_digests.count)
        end

        def delete_lock(digest)
          digests.delete_by_digest(digest)
          expiring_digests.delete_by_digest(digest)
        end

        def unique_template(name) = File.read(File.join(VIEWS, "#{name}.erb"))
        def digests = @digests ||= Digests.new
        def expiring_digests = @expiring_digests ||= ExpiringDigests.new
        def changelog = @changelog ||= Changelog.new

        def page_params
          @filter = url_params('filter').to_s
          @filter = '*' if @filter.empty?
          @count = (url_params('count') || 100).to_i
          @count = 100 unless @count.positive?
          @current_cursor = url_params('cursor').to_i
          @prev_cursor = url_params('prev_cursor').to_i
        end

        def cparams(options)
          params.transform_keys(&:to_s).merge(options.transform_keys(&:to_s)).filter_map do |key, value|
            "#{key}=#{CGI.escape(value.to_s)}" if SAFE_CPARAMS.include?(key)
          end.join('&')
        end

        def display_lock_args(args, truncate_after_chars = 2000)
          return 'Invalid job payload, args is nil' if args.nil?
          return "Invalid job payload, args must be an Array, not #{args.class.name}" unless args.is_a?(Array)

          args.map { |arg| h(truncate(to_display(arg), truncate_after_chars || 1_000_000)) }.join(', ')
        end

        def _safe_relative_time(time)
          return unless time

          time = case time
                 when ::Time then time
                 when ::Numeric then ::Time.at(time)
                 else ::Time.parse(time.to_s)
                 end
          stamp = time.getutc.iso8601
          %(<time class="ltr" dir="ltr" title="#{stamp}" datetime="#{stamp}">#{h(time)}</time>)
        end
      end
    end
  end
end
