# frozen_string_literal: true

require_relative '../test_helper'
require 'bundler'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# An app that dropped every sidekiq-* add-on needs neither real Sidekiq nor the
# `sidekiq` shim gem: a Gemfile naming wurk alone resolves with no `sidekiq`
# spec at all, and every `require "sidekiq…"` path such an app uses is a file in
# wurk's own lib/. docs/migrate-from-sidekiq.md ("Dropping the shim") says so.
class WurkAloneBundleTest < Wurk::Test::UnitCase
  parallelize_me!

  ROOT = File.expand_path('../..', __dir__)
  LIB = File.join(ROOT, 'lib')

  # What a Rails app on wurk alone requires, by hand or from Bundler.require.
  PATHS = %w[sidekiq sidekiq/api sidekiq/capsule sidekiq/job_retry sidekiq/testing sidekiq/web
             sidekiq/cron sidekiq/cron/web sidekiq-cron wurk/sentry].freeze

  def test_a_gemfile_with_wurk_alone_resolves_without_a_sidekiq_gem
    Dir.mktmpdir do |dir|
      gemfile = File.join(dir, 'Gemfile')
      File.write(gemfile, "source 'https://rubygems.org'\ngem 'wurk', path: #{ROOT.inspect}\n")
      definition = Bundler::Definition.build(gemfile, File.join(dir, 'Gemfile.lock'), nil)
      definition.resolve_with_cache!
      names = definition.specs.map(&:name)

      assert_includes names, 'wurk'
      refute_includes names, 'sidekiq'
    end
  end

  def test_the_gemspec_declares_no_sidekiq_dependency_and_ships_the_sidekiq_command
    spec = Gem::Specification.load(File.join(ROOT, 'wurk.gemspec'))

    assert_empty spec.dependencies.map(&:name).grep(/\Asidekiq/)
    assert_includes spec.executables, 'sidekiq'
  end

  def test_every_path_resolves_to_wurks_lib
    script = 'require "json"; print JSON.dump(ARGV.to_h { |path| [path, $LOAD_PATH.resolve_feature_path(path)&.last] })'
    out, err, status = Open3.capture3({ 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile') }, RbConfig.ruby,
                                      '-rbundler/setup', '-e', script, *PATHS)

    assert_predicate status, :success?, err
    resolved = JSON.parse(out)

    PATHS.each { |path| assert_equal File.join(LIB, "#{path}.rb"), resolved[path], path }
  end
end
