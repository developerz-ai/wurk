# frozen_string_literal: true

require 'rails/generators'

module Wurk
  module Generators
    # `bin/rails g wurk:install`
    # Writes a config initializer and adds a commented-out mount line to routes.
    # The host app picks the mount path; the generator suggests /wurk.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      def copy_initializer
        template 'wurk.rb', 'config/initializers/wurk.rb'
      end

      def insert_mount_line
        route(%(# mount Wurk::Engine => "/wurk"  # uncomment to expose the Wurk dashboard))
      end

      def show_next_steps
        say <<~STEPS

          Next steps:
            1. Set the queue adapter if you use Active Job: config.active_job.queue_adapter = :wurk
            2. Start workers: bundle exec wurkswarm (or bundle exec wurk for one process)
            3. To use the dashboard, uncomment the mount line in config/routes.rb.
               It has no login of its own, so put it behind authentication first:
               docs/authentication.md in the wurk gem's repository
        STEPS
      end
    end
  end
end
