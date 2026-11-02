# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'
require 'rbconfig'
require 'wurk/version'

# Hosts start workers with `bundle exec sidekiq`, and the shim gem is what
# resolves `sidekiq` in a bundle without the real gem.
class SidekiqShimExecutableTest < Wurk::Test::UnitCase
  SHIM = File.expand_path('../../ecosystem/sidekiq-shim', __dir__)
  EXE = File.join(SHIM, 'exe', 'sidekiq')

  def test_gemspec_declares_the_executable
    spec = Dir.chdir(SHIM) { Gem::Specification.load('sidekiq.gemspec') }

    assert_equal 'exe', spec.bindir
    assert_includes spec.executables, 'sidekiq'
    assert_includes spec.files, 'exe/sidekiq'
  end

  def test_executable_bit_is_set
    assert File.executable?(EXE), "#{EXE} must be executable"
  end

  def test_runs_the_wurk_cli
    out, status = Open3.capture2e(RbConfig.ruby, EXE, '--version')

    assert_predicate status, :success?, out
    assert_includes out, Wurk::VERSION
  end
end
