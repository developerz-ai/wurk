# frozen_string_literal: true

require_relative '../test_helper'

# The `wurk:install` initializer template ships only commented-out examples, but
# each must be a *working* setter — otherwise a user who uncomments one hits
# NoMethodError at boot (regression for #79, where `config.workers` and
# `config.shutdown_timeout` didn't exist). Pull every `# config…` example out of
# the template and run it against a fresh Configuration.
class InstallTemplateTest < Wurk::Test::UnitCase
  parallelize_me!

  TEMPLATE = File.expand_path('../../lib/generators/wurk/install/templates/wurk.rb', __dir__)

  def test_every_commented_config_example_is_a_working_setter
    examples = File.readlines(TEMPLATE)
                   .map(&:strip)
                   .select { |line| line.start_with?('# config') }
                   .map { |line| line.sub(/\A# /, '') }

    refute_empty examples, 'expected the template to carry commented config examples'

    examples.each do |stmt|
      config = Wurk::Configuration.new # rubocop:disable Lint/UselessAssignment
      eval(stmt) # rubocop:disable Security/Eval -- `config` (above) is the local the example references
    rescue StandardError, ScriptError => e
      flunk "template example `#{stmt}` is not a working setter: #{e.class}: #{e.message}"
    end
  end
end
