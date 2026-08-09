# frozen_string_literal: true

require_relative '../test_helper'
require 'wurk/api'

# Slice 07, task 48 — the predicate the engine's conditional mount hangs off
# (config/routes.rb). Two questions answered without loading App: is the API on
# at all, and is this path part of its contract. The three mounts themselves are
# proven end-to-end in test/engine/api_mount_modes_test.rb.
class ApiMountTest < Wurk::Test::UnitCase
  parallelize_me!

  TOKEN = 'api-mount-test-token-0123456789'

  # The whole additive invariant in one assertion: no token, no surface. The
  # engine's constraint fails, Rails falls through to the next route, and the
  # path answers exactly as it did before wurk was mounted.
  def test_no_token_registered_claims_nothing
    refute Wurk::API.serves?('/v1', bare_config)
    refute Wurk::API.serves?('/v1/jobs', bare_config)
  end

  def test_a_registered_token_claims_the_version_root_and_everything_under_it
    assert Wurk::API.serves?('/v1', config)
    assert Wurk::API.serves?('/v1/jobs', config)
    assert Wurk::API.serves?('/v1/queues/critical', config)
  end

  # Nested in the engine this plane shares the /api prefix with the dashboard's
  # own JSON API, whose routes are declared first. A path that misses those must
  # stay a Rails route miss rather than reaching the machine plane's auth gate
  # and coming back as a bearer challenge for a route that never existed.
  def test_a_dashboard_api_path_is_not_claimed
    refute Wurk::API.serves?('/stats', config)
    refute Wurk::API.serves?('/queues/critical', config)
    refute Wurk::API.serves?('/', config)
  end

  # `start_with?('/v1')` alone would claim these.
  def test_a_path_that_merely_starts_with_the_version_string_is_not_claimed
    refute Wurk::API.serves?('/v10', config)
    refute Wurk::API.serves?('/v1x/jobs', config)
  end

  # An unknown version is the App's 404 to answer (unsupported_api_version, with
  # the versions it does serve), so the mount has to hand it over rather than
  # leaving the client a bare Rails route miss.
  def test_an_unknown_version_is_not_claimed_here
    refute Wurk::API.serves?('/v2/jobs', config)
  end

  def test_the_version_prefix_is_the_one_the_app_serves_under
    assert_equal '/v1', Wurk::API::VERSION_PREFIX
    assert_equal ['v1'], Wurk::API::SUPPORTED_VERSIONS
  end

  private

  def config
    @config ||= Wurk::Configuration.new.tap { |cfg| cfg.api_token(TOKEN, scopes: %i[admin]) }
  end

  def bare_config = @bare_config ||= Wurk::Configuration.new
end
