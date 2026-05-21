# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/dashboard_manifest'
require 'tmpdir'
require 'fileutils'

class DashboardManifestTest < Wurk::Test::UnitCase
  parallelize_me!

  def setup
    @root = ::Pathname.new(::Dir.mktmpdir('wurk-manifest-test'))
    @dir = @root.join('vendor', 'assets', 'dashboard')
    @dir.mkpath
  end

  def teardown
    ::FileUtils.remove_entry(@root.to_s) if @root.exist?
  end

  def test_check_returns_true_on_match
    write_manifest('version' => '1.2.3')

    assert(::Wurk::DashboardManifest.check!(root: @root, expected: '1.2.3'))
  end

  def test_check_raises_missing_when_file_absent
    assert_raises(::Wurk::DashboardManifest::MissingError) do
      ::Wurk::DashboardManifest.check!(root: @root, expected: '1.2.3')
    end
  end

  def test_check_raises_version_mismatch
    write_manifest('version' => '0.9.0')

    assert_raises(::Wurk::DashboardManifest::VersionMismatch) do
      ::Wurk::DashboardManifest.check!(root: @root, expected: '1.2.3')
    end
  end

  def test_check_raises_version_mismatch_when_version_missing
    write_manifest('built_at' => 'now')

    assert_raises(::Wurk::DashboardManifest::VersionMismatch) do
      ::Wurk::DashboardManifest.check!(root: @root, expected: '1.2.3')
    end
  end

  def test_path_resolves_under_vendor_assets_dashboard
    p = ::Wurk::DashboardManifest.path(@root)

    assert_equal @root.join('vendor', 'assets', 'dashboard', 'wurk-manifest.json'), p
  end

  private

  def write_manifest(data)
    @dir.join('wurk-manifest.json').write(::JSON.generate(data))
  end
end
