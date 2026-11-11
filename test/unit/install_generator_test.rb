# frozen_string_literal: true

require_relative '../test_helper'
require 'tmpdir'
require 'generators/wurk/install/install_generator'

# `bin/rails g wurk:install` against a scratch app root: it must write the
# initializer verbatim from the template and add the mount line commented out,
# so installing never exposes the dashboard without the host choosing a path.
class InstallGeneratorTest < Wurk::Test::UnitCase
  parallelize_me!

  TEMPLATE = File.expand_path('../../lib/generators/wurk/install/templates/wurk.rb', __dir__)

  def test_writes_the_initializer_and_a_commented_mount_line
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'config'))
      File.write(File.join(root, 'config/routes.rb'), "Rails.application.routes.draw do\nend\n")

      out, = capture_io { Wurk::Generators::InstallGenerator.start([], destination_root: root) }

      assert_equal File.read(TEMPLATE), File.read(File.join(root, 'config/initializers/wurk.rb'))
      assert_match(%r{^\s*# mount Wurk::Engine => "/wurk"}, File.read(File.join(root, 'config/routes.rb')))
      assert_match(/put it behind authentication/, out)
      assert_match(/bundle exec wurkswarm/, out)
    end
  end

  LOCK_WITH_CRON = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        fugit (1.11.1)
        sidekiq (7.3.10)
        sidekiq-cron (2.3.1)
          fugit (~> 1.8, >= 1.11.1)
          sidekiq (>= 6.5.0)
        sidekiq-pro (7.3.6)
          sidekiq (>= 7.3.7, < 8)
        sidekiq-unique-jobs (8.0.11)
          sidekiq (>= 7.0.0, < 9.0.0)

    PLATFORMS
      ruby

    DEPENDENCIES
      sidekiq-cron
      sidekiq-unique-jobs

    BUNDLED WITH
       2.5.0
  LOCK

  def run_generator_in(files)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'config'))
      File.write(File.join(root, 'config/routes.rb'), "Rails.application.routes.draw do\nend\n")
      files.each { |name, body| File.write(File.join(root, name), body) }
      out, = capture_io { Wurk::Generators::InstallGenerator.start([], destination_root: root) }
      return [out, files.to_h { |name, _| [name, File.read(File.join(root, name))] }]
    end
  end

  def test_prints_the_pinned_shim_line_for_gems_that_depend_on_sidekiq
    out, files = run_generator_in('Gemfile.lock' => LOCK_WITH_CRON)

    assert_includes out, 'sidekiq-cron, sidekiq-unique-jobs depend on the sidekiq gem'
    refute_includes out, 'sidekiq-pro,'
    assert_includes out, "tag: \"v#{Wurk::VERSION}\", glob: \"ecosystem/sidekiq-shim/*.gemspec\""
    assert_equal LOCK_WITH_CRON, files['Gemfile.lock'], 'the generator must not edit the lockfile'
  end

  def test_no_shim_line_once_the_shim_is_bundled
    lock = LOCK_WITH_CRON.sub("    sidekiq (7.3.10)\n", "    sidekiq (8.1.5)\n      wurk (= #{Wurk::VERSION})\n")
    out, = run_generator_in('Gemfile.lock' => lock)

    refute_includes out, 'depend on the sidekiq gem'
  end

  def test_no_shim_line_without_a_lockfile_or_dependents
    out, = run_generator_in({})

    refute_includes out, 'depend on the sidekiq gem'
    refute_includes out, 'Procfile'
  end

  def test_prints_the_procfile_worker_lines
    procfile = "web: bundle exec puma\nworker: bundle exec sidekiq -C config/sidekiq.yml\n"
    out, files = run_generator_in('Procfile' => procfile)

    assert_includes out, 'Procfile worker lines keep working'
    assert_includes out, '  worker: bundle exec sidekiq -C config/sidekiq.yml'
    refute_includes out, 'web: bundle exec puma'
    assert_includes out, 'bundle exec wurkswarm'
    assert_equal procfile, files['Procfile']
  end
end
