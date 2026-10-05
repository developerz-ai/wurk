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

      capture_io { Wurk::Generators::InstallGenerator.start([], destination_root: root) }

      assert_equal File.read(TEMPLATE), File.read(File.join(root, 'config/initializers/wurk.rb'))
      assert_match(%r{^\s*# mount Wurk::Engine => "/wurk"}, File.read(File.join(root, 'config/routes.rb')))
    end
  end
end
