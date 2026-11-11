# frozen_string_literal: true

require 'json'
require 'rubygems/package'

# Release-time assertions shared by the Rakefile and its tests. Each raising
# method aborts the process (SystemExit) with an actionable message so the
# release gate fails loudly in CI and locally. Lives under tasks/, not lib/, so
# it is never packaged into the published gem.
module ReleaseHelpers
  # The checked-in guard list, one test file per line. A line naming a missing file
  # raises: Rake::TestTask would otherwise drop it and guard less, silently.
  def self.guard_manifest(path)
    root = File.dirname(path, 2)
    File.readlines(path, chomp: true).reject { |line| line.empty? || line.start_with?('#') }.each do |line|
      raise "#{path} lists #{line}, which does not exist" unless File.exist?(File.join(root, line))
    end
  end

  # nil when the built dashboard matches `version`, otherwise what to do about it.
  def self.dashboard_bundle_stale(bundle_dir, version)
    manifest = File.join(bundle_dir, 'wurk-manifest.json')
    missing = "the built dashboard has no #{File.basename(manifest)}: run `bin/rake frontend:build`."
    return missing unless File.exist?(manifest)

    built = JSON.parse(File.read(manifest))['version']
    return if built == version

    "the built dashboard is #{built.inspect} and Wurk::VERSION is #{version.inspect}: run `bin/rake frontend:build`."
  rescue JSON::ParserError
    "the built dashboard's #{File.basename(manifest)} is unreadable: run `bin/rake frontend:build`."
  end

  module_function

  CI_ONLY_MESSAGE = <<~MSG
    ✗ Releases are not cut from a workstation.
      A release IS merging a lib/wurk/version.rb bump (plus its
      docs/changelog/<version>.md notes) to main: release.yml then gates,
      publishes the gem, and cuts the tag + GitHub Release itself. The tag is an output, never an input.
      See RELEASE.md ("Cutting a release").
  MSG

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

  # The tag the release lane cuts for a given Wurk::VERSION — the exact inverse
  # of tag_matches_version!. Git spells a prerelease with a hyphen
  # ("v1.0.0-rc1"), RubyGems with a dot ("1.0.0.rc1"), so the dot introducing the
  # prerelease suffix (the first one followed by a letter) becomes a hyphen.
  # Deriving the tag from the version is what makes the two unable to disagree.
  def git_tag_for(version)
    "v#{version.sub(/\.(?=[a-zA-Z])/, '-')}"
  end

  # The release job derives its tag and passes it here as WURK_RELEASE_TAG; a
  # local gate run falls back to GITHUB_REF_NAME. Git tags spell a prerelease
  # with a hyphen ("v1.0.0-rc1") while RubyGems uses a dot ("1.0.0.rc1"); treat
  # them as the same. No-op when not building off a v-tag.
  def tag_matches_version!(version, tag = ENV.fetch('WURK_RELEASE_TAG', nil) || ENV.fetch('GITHUB_REF_NAME', ''))
    return unless tag.start_with?('v')

    from_tag = tag.delete_prefix('v').tr('-', '.')
    return if from_tag == version

    abort "release:check ✗ tag #{tag} does not match Wurk::VERSION #{version} (expected v#{version})"
  end

  # Second line behind release.yml's own main-only guard: a workflow_dispatch
  # from a feature branch must never publish that branch's code as a gem. Keyed
  # on GITHUB_REF, which Actions always sets; empty means a local run, where
  # there is no publish to guard.
  def ref_is_main!(ref = ENV.fetch('GITHUB_REF', ''))
    return if ref.empty? || ref == 'refs/heads/main'

    abort "release:check ✗ releases publish only from refs/heads/main (running on #{ref})"
  end

  # The notes file is what release.yml lifts into the GitHub Release
  # (bin/changelog-section) after the gem is already pushed, so a missing or
  # empty one has to fail here, before anything publishes.
  def changelog_has_version!(root, version)
    notes = File.join('docs', 'changelog', "#{version}.md")
    path = File.join(root, notes)
    unless File.file?(path)
      abort "release:check ✗ #{notes} is missing: `git mv docs/changelog/unreleased.md #{notes}`, " \
            "title it `# #{version} — YYYY-MM-DD`, and start a new docs/changelog/unreleased.md"
    end
    if File.read(path).sub(/\A# [^\n]*\n/, '').strip.empty?
      abort "release:check ✗ #{notes} has no notes under its title"
    end
    return if File.read(File.join(root, 'CHANGELOG.md')).match?(/^## \[#{Regexp.escape(version)}\] - /)

    abort "release:check ✗ CHANGELOG.md has no `## [#{version}] - YYYY-MM-DD` index entry for Wurk::VERSION"
  end

  # Every release bump must also advance the [Unreleased] compare link; 1.7.4
  # and 1.7.5 both shipped with it still comparing from v1.7.3. The expected
  # from-tag is what git_tag_for derives, so link and tag cannot disagree either.
  def changelog_unreleased_link_current!(changelog, version)
    tag = git_tag_for(version)
    link = changelog[/^\[Unreleased\]:\s*(\S+)/, 1]
    return if link&.end_with?("compare/#{tag}...HEAD")

    found = link ? "it reads #{link}" : 'there is no [Unreleased] reference line'
    abort "release:check ✗ CHANGELOG.md [Unreleased] link must compare from #{tag}...HEAD " \
          "(#{found})"
  end

  # demo/Gemfile.lock pins the path-sourced wurk at the version it was locked
  # against; the Dockerfile installs it frozen, so a bump without a re-lock
  # breaks the demo image build — after the gem is already live.
  def demo_lock_matches_version!(lockfile, version)
    locked = lockfile[/^PATH\n  remote: \.\.\n  specs:\n    wurk \(([^)]+)\)$/, 1]
    return if locked == version

    found = locked ? "it pins wurk #{locked}" : 'it has no path-sourced wurk entry'
    abort "release:check ✗ demo/Gemfile.lock is stale for Wurk::VERSION #{version} (#{found}) — " \
          'run `bundle exec rake release:relock_demo` and commit the lock'
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
