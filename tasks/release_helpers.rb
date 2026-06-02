# frozen_string_literal: true

require 'rubygems/package'

# Release-time assertions shared by the Rakefile and its tests. Each raising
# method aborts the process (SystemExit) with an actionable message so the
# release gate fails loudly in CI and locally. Lives under tasks/, not lib/, so
# it is never packaged into the published gem.
module ReleaseHelpers
  module_function

  # Files the precompiled SPA must ship — consumers never run Node, so the gem is
  # broken without all three. Paths are relative to the gem root (as packaged).
  DASHBOARD_REQUIRED_FILES = [
    'vendor/assets/dashboard/index.html',
    'vendor/assets/dashboard/wurk-manifest.json'
  ].freeze

  def dashboard_bundle_present!(bundle_dir)
    index = File.join(bundle_dir, 'index.html')
    manifest = File.join(bundle_dir, 'wurk-manifest.json')
    scripts = Dir.glob(File.join(bundle_dir, 'assets', '*.js'))
    non_empty = ->(path) { File.file?(path) && File.size(path).positive? }
    return if File.file?(index) && non_empty.call(manifest) && scripts.any? { |f| non_empty.call(f) }

    abort "release:check ✗ dashboard bundle incomplete in #{bundle_dir} " \
          '(need index.html, a non-empty wurk-manifest.json, and a non-empty assets/*.js — ' \
          'run `bundle exec rake frontend:build` first)'
  end

  # On a CI tag push GITHUB_REF_NAME is the tag. Git tags spell a prerelease with
  # a hyphen ("v1.0.0-rc1") while RubyGems uses a dot ("1.0.0.rc1"); treat them as
  # the same. No-op when not building off a v-tag (e.g. a local gate run).
  def tag_matches_version!(version, tag = ENV.fetch('GITHUB_REF_NAME', ''))
    return unless tag.start_with?('v')

    from_tag = tag.delete_prefix('v').tr('-', '.')
    return if from_tag == version

    abort "release:check ✗ tag #{tag} does not match Wurk::VERSION #{version} (expected v#{version})"
  end

  def changelog_has_version!(changelog, version)
    return if changelog.match?(/^## \[#{Regexp.escape(version)}\]/)

    abort "release:check ✗ CHANGELOG.md has no `## [#{version}]` section matching Wurk::VERSION"
  end

  # Read the packaged file list straight out of the built .gem (no install) and
  # assert the precompiled dashboard actually shipped inside it.
  def gem_contains_dashboard!(gem_path)
    entries = Gem::Package.new(gem_path).contents
    missing = DASHBOARD_REQUIRED_FILES.reject { |f| entries.include?(f) }
    missing << 'assets/*.js' unless dashboard_js?(entries)
    return if missing.empty?

    abort "release:package ✗ #{File.basename(gem_path)} does not ship the dashboard bundle " \
          "(missing #{missing.join(', ')})"
  end

  def dashboard_js?(entries)
    entries.any? { |f| f.start_with?('vendor/assets/dashboard/assets/') && f.end_with?('.js') }
  end
end
