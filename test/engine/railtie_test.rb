# frozen_string_literal: true

require_relative '../engine_test_helper'

# The railtie owns two boot decisions, both gated by Railtie.skip_boot?:
#   * entering server mode before config/initializers load (#191), and
#   * forking + supervising the swarm in after_initialize.
# A process that won't run workers (WURK_DISABLED / console / test) is not a
# server and must do neither — otherwise the test suite itself would fork a
# swarm and flip Sidekiq.server? on every engine run.
class RailtieTest < Wurk::Test::EngineCase
  def test_skip_boot_is_true_in_test_environment
    assert_predicate ::Rails.env, :test?, 'precondition: engine tests run under the test env'
    assert_predicate Wurk::Railtie, :skip_boot?, 'test env must never auto-boot the swarm or enter server mode'
  end

  def test_skip_boot_is_true_when_wurk_disabled
    original = ENV.fetch('WURK_DISABLED', nil)
    ENV['WURK_DISABLED'] = '1'

    assert_predicate Wurk::Railtie, :skip_boot?
  ensure
    original.nil? ? ENV.delete('WURK_DISABLED') : (ENV['WURK_DISABLED'] = original)
  end
end
