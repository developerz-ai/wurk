# frozen_string_literal: true

require 'rails/generators'
require 'bundler'
require 'wurk/version'

module Wurk
  module Generators
    # `bin/rails g wurk:install`
    # Writes a config initializer and adds a commented-out mount line to routes.
    # The host app picks the mount path; the generator suggests /wurk.
    # Reads Gemfile.lock and Procfile to print what a Sidekiq app must change;
    # it edits neither.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path('templates', __dir__)

      # Sidekiq's own tiers depend on `sidekiq` too, but the swap removes them.
      SIDEKIQ_TIERS = %w[sidekiq sidekiq-pro sidekiq-ent].freeze
      SIDEKIQ_COMMAND = /\bsidekiq(?:swarm)?\b/

      def copy_initializer
        template 'wurk.rb', 'config/initializers/wurk.rb'
      end

      def insert_mount_line
        route(%(# mount Wurk::Engine => "/wurk"  # uncomment to expose the Wurk dashboard))
      end

      def show_shim_line
        dependents = sidekiq_dependents
        return if dependents.empty?

        say <<~SHIM

          #{dependents.join(', ')} #{dependents.size == 1 ? 'depends' : 'depend'} on the sidekiq gem, which would load real Sidekiq next to Wurk.
          Keep #{dependents.size == 1 ? 'it' : 'them'} by adding the shim to the Gemfile, in place of gem "sidekiq":
            gem "sidekiq", github: "developerz-ai/wurk", tag: "v#{Wurk::VERSION}", glob: "ecosystem/sidekiq-shim/*.gemspec"
        SHIM
      end

      def show_procfile_runner
        lines = procfile_sidekiq_lines
        return if lines.empty?

        say "\nProcfile worker lines keep working: wurk ships the sidekiq and sidekiqswarm commands."
        lines.each { |line| say "  #{line}" }
        say 'For one process per core, run `bundle exec wurkswarm` with the same flags.'
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

      private

      def sidekiq_dependents
        specs = locked_specs
        # The shim is the `sidekiq` spec that depends on wurk: already in place.
        return [] if specs.any? { |spec| spec.name == 'sidekiq' && depends_on?(spec, 'wurk') }

        specs.select { |spec| depends_on?(spec, 'sidekiq') }.map(&:name).uniq
             .reject { |name| SIDEKIQ_TIERS.include?(name) }.sort
      end

      def locked_specs
        lockfile = File.join(destination_root, 'Gemfile.lock')
        File.file?(lockfile) ? ::Bundler::LockfileParser.new(File.read(lockfile)).specs : []
      end

      def depends_on?(spec, name)
        spec.dependencies.any? { |dep| dep.name == name }
      end

      def procfile_sidekiq_lines
        procfile = File.join(destination_root, 'Procfile')
        return [] unless File.file?(procfile)

        File.readlines(procfile, chomp: true).grep(SIDEKIQ_COMMAND)
      end
    end
  end
end
