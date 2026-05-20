# frozen_string_literal: true

require "rails/generators"

module Wurk
  module Generators
    # `bin/rails g wurk:install`
    # Writes a config initializer and adds a commented-out mount line to routes.
    # The host app picks the mount path; the generator suggests /wurk.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def copy_initializer
        template "wurk.rb", "config/initializers/wurk.rb"
      end

      def insert_mount_line
        route(%(# mount Wurk::Engine => "/wurk"  # uncomment to expose the Wurk dashboard))
      end
    end
  end
end
