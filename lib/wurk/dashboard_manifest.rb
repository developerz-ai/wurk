# frozen_string_literal: true

require 'json'
require 'pathname'

module Wurk
  # Validates that the precompiled dashboard bundle in vendor/assets matches
  # this gem version. Run from the engine initializer in production to catch
  # packaging mistakes (forgotten `frontend:build`, stale vendor/assets,
  # mismatched release) at boot rather than as a runtime 500.
  module DashboardManifest
    class MissingError < ::StandardError; end
    class VersionMismatch < ::StandardError; end

    MANIFEST_NAME = 'wurk-manifest.json'

    class << self
      def path(root)
        ::Pathname.new(root).join('vendor', 'assets', 'dashboard', MANIFEST_NAME)
      end

      def check!(root: ::Wurk::Engine.root, expected: ::Wurk::VERSION)
        file = path(root)
        unless file.exist?
          raise MissingError,
                "Wurk dashboard manifest missing at #{file}. " \
                'Did `bin/rake frontend:build` run before `gem build`?'
        end

        data = ::JSON.parse(file.read)
        actual = data['version']
        return true if actual == expected

        raise VersionMismatch,
              "Wurk dashboard manifest version #{actual.inspect} != gem #{expected.inspect}"
      end
    end
  end
end
