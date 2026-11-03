# frozen_string_literal: true

require 'minitest/autorun'
require 'json'

require_relative '../../lib/wurk/version'

# The dashboard SPA is a build artifact, not a committed file: a lib/wurk/
# version.rb bump leaves the bundle stamped with the old version until
# frontend:build reruns. rake test and test:engine refuse a stale bundle up
# front (frontend:ensure_build aborts), but the other entry points — test:unit,
# test:integration, test:guards — never see that prerequisite, and a test file
# run directly bypasses rake entirely; bin/check's fast stage stayed green on
# exactly such a box. Reads files only: no Redis, no Rails, nothing else
# loaded. No index.html is a fresh clone (skip, #257); anything else wrong —
# a wurk-manifest.json missing beside a built index.html (an interrupted
# frontend build), an unreadable manifest, the wrong stamp — is a setup
# failure bin/setup exists to heal, so fail naming both versions and the
# fix. Skipping a half-built bundle would leave test:unit green on the very
# box where rake test aborts.
class DashboardBundleFreshnessTest < Minitest::Test
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  BUNDLE_DIR = File.join(ROOT, 'vendor', 'assets', 'dashboard')
  MANIFEST = File.join(BUNDLE_DIR, 'wurk-manifest.json')
  INDEX = File.join(BUNDLE_DIR, 'index.html')

  def test_the_built_dashboard_bundle_matches_wurk_version
    skip 'fresh clone, bundle not built' unless File.file?(INDEX)

    unless File.file?(MANIFEST)
      flunk "#{MANIFEST} is missing while #{INDEX} is present — an interrupted " \
            'frontend build: run `bin/setup` (or `bin/rake frontend:build`).'
    end

    built =
      begin
        JSON.parse(File.read(MANIFEST))['version']
      rescue JSON::ParserError
        flunk "#{MANIFEST} is not valid JSON: run `bin/setup` (or `bin/rake frontend:build`)."
      end

    assert_equal ::Wurk::VERSION, built,
                 "the built dashboard is #{built.inspect} and Wurk::VERSION is " \
                 "#{::Wurk::VERSION.inspect}: run `bin/setup` (or `bin/rake frontend:build`)."
  end
end
