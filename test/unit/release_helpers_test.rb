# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../tasks/release_helpers'

class ReleaseHelpersTest < Wurk::Test::UnitCase
  parallelize_me!

  # --- tag_matches_version! --------------------------------------------

  def test_tag_matches_plain_version
    ReleaseHelpers.tag_matches_version!('1.0.0', 'v1.0.0')
  end

  def test_tag_matches_prerelease_git_hyphen_to_gem_dot
    ReleaseHelpers.tag_matches_version!('1.0.0.rc1', 'v1.0.0-rc1')
  end

  def test_tag_matches_prerelease_dot_form
    ReleaseHelpers.tag_matches_version!('1.0.0.rc1', 'v1.0.0.rc1')
  end

  def test_tag_skipped_when_not_a_v_tag
    ReleaseHelpers.tag_matches_version!('1.0.0', '')
    ReleaseHelpers.tag_matches_version!('1.0.0', 'main')
  end

  def test_tag_mismatch_aborts
    err = assert_raises(SystemExit) do
      silence_stderr { ReleaseHelpers.tag_matches_version!('1.0.0', 'v2.0.0') }
    end
    refute_predicate err, :success?
  end

  # --- changelog_has_version! ------------------------------------------

  def test_changelog_present
    ReleaseHelpers.changelog_has_version!("## [1.2.3] - 2026-01-01\n- x\n", '1.2.3')
  end

  def test_changelog_missing_aborts
    assert_raises(SystemExit) do
      silence_stderr { ReleaseHelpers.changelog_has_version!("## [1.0.0]\n", '9.9.9') }
    end
  end

  # --- dashboard_bundle_present! ---------------------------------------

  def test_bundle_present_passes
    Dir.mktmpdir do |dir|
      write_bundle(dir)
      ReleaseHelpers.dashboard_bundle_present!(dir)
    end
  end

  def test_bundle_missing_manifest_aborts
    Dir.mktmpdir do |dir|
      write_bundle(dir)
      File.delete(File.join(dir, 'wurk-manifest.json'))
      assert_raises(SystemExit) do
        silence_stderr { ReleaseHelpers.dashboard_bundle_present!(dir) }
      end
    end
  end

  def test_bundle_empty_js_aborts
    Dir.mktmpdir do |dir|
      write_bundle(dir, js_content: '')
      assert_raises(SystemExit) do
        silence_stderr { ReleaseHelpers.dashboard_bundle_present!(dir) }
      end
    end
  end

  # --- gem_contains_dashboard! -----------------------------------------

  def test_gem_with_dashboard_passes
    Dir.mktmpdir do |dir|
      gem_path = build_fake_gem(dir, include_dashboard: true)
      ReleaseHelpers.gem_contains_dashboard!(gem_path)
    end
  end

  def test_gem_without_dashboard_aborts
    Dir.mktmpdir do |dir|
      gem_path = build_fake_gem(dir, include_dashboard: false)
      assert_raises(SystemExit) do
        silence_stderr { ReleaseHelpers.gem_contains_dashboard!(gem_path) }
      end
    end
  end

  private

  def write_bundle(dir, js_content: 'console.log(1)')
    FileUtils.mkdir_p(File.join(dir, 'assets'))
    File.write(File.join(dir, 'index.html'), '<html></html>')
    File.write(File.join(dir, 'wurk-manifest.json'), '{"index.html":{}}')
    File.write(File.join(dir, 'assets', 'index-abc.js'), js_content)
  end

  # Package a throwaway gem in `dir`, optionally with the dashboard bundle, and
  # return the absolute .gem path. chdir is process-global but safe here: each
  # test class runs in its own fork and tests within a class run sequentially.
  def build_fake_gem(dir, include_dashboard:) # rubocop:disable Metrics/AbcSize
    Dir.chdir(dir) do
      FileUtils.mkdir_p('lib')
      File.write('lib/fake.rb', "# fake\n")
      files = ['lib/fake.rb']
      if include_dashboard
        FileUtils.mkdir_p('vendor/assets/dashboard/assets')
        File.write('vendor/assets/dashboard/index.html', '<html></html>')
        File.write('vendor/assets/dashboard/wurk-manifest.json', '{}')
        File.write('vendor/assets/dashboard/assets/index-x.js', 'x')
        files += Dir['vendor/assets/dashboard/**/*'].select { |f| File.file?(f) }
      end
      spec = Gem::Specification.new do |s|
        s.name = 'fakegem'
        s.version = '0.0.1'
        s.summary = 'fake'
        s.authors = ['t']
        s.files = files
        s.required_ruby_version = '>= 3.2.0'
      end
      with_silent_gem_ui { Gem::Package.build(spec) }
      File.expand_path('fakegem-0.0.1.gem')
    end
  end

  def silence_stderr
    orig = $stderr
    $stderr = File.open(File::NULL, 'w')
    yield
  ensure
    $stderr.close
    $stderr = orig
  end

  # Gem::Package.build narrates through Gem's global UI; swap it for a silent one
  # so the build doesn't spam test output (and doesn't memoize a stream we close).
  def with_silent_gem_ui
    orig = Gem::DefaultUserInteraction.ui
    silent = Gem::SilentUI.new
    Gem::DefaultUserInteraction.ui = silent
    yield
  ensure
    Gem::DefaultUserInteraction.ui = orig
    silent&.close
  end
end
