# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'
require 'rbconfig'
require 'wurk/version'

# Hosts start workers with `bundle exec sidekiq -C config/sidekiq.yml`. wurk
# ships that command, so the one-line gem swap leaves Procfiles, systemd units
# and k8s manifests as they were.
class SidekiqExecutableTest < Wurk::Test::UnitCase
  ROOT = File.expand_path('../..', __dir__)
  EXE = File.join(ROOT, 'exe', 'sidekiq')

  def spec
    @spec ||= Dir.chdir(ROOT) { Gem::Specification.load('wurk.gemspec') }
  end

  def test_gemspec_ships_the_upstream_command_names
    assert_equal 'exe', spec.bindir
    %w[sidekiq sidekiqswarm wurk wurkswarm].each do |name|
      assert_includes spec.executables, name
      assert_includes spec.files, "exe/#{name}"
    end
  end

  def test_executable_bit_is_set
    assert File.executable?(EXE), "#{EXE} must be executable"
  end

  def test_runs_the_wurk_cli
    out, status = Open3.capture2e({ 'COVERAGE' => nil }, RbConfig.ruby, EXE, '--version')

    assert_predicate status, :success?, out
    assert_includes out, Wurk::VERSION
  end

  def test_post_install_message_names_the_runner_shim_and_preflight
    message = spec.post_install_message

    assert_includes message, 'bundle exec sidekiq'
    assert_includes message, 'shim'
    assert_includes message, 'wurk preflight'
  end
end
