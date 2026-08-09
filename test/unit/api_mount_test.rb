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
    # A queue may legally be named "v2". Only the first segment names a version.
    refute Wurk::API.serves?('/queues/v2', config)
  end

  # `start_with?('/v1')` alone would claim these: neither names a version, so
  # both belong to whatever else is mounted here.
  def test_a_path_that_merely_starts_with_the_version_string_is_not_claimed
    refute Wurk::API.serves?('/v1x/jobs', config)
    refute Wurk::API.serves?('/version', config)
    refute Wurk::API.serves?('/v', config)
  end

  # An unknown version is the App's 404 to answer (unsupported_api_version, with
  # the versions it does serve), so the mount hands it over rather than leaving
  # the client a bare Rails route miss — the answer the other two mounts give.
  def test_an_unknown_version_is_claimed_so_the_app_can_refuse_it_by_name
    assert Wurk::API.serves?('/v2', config)
    assert Wurk::API.serves?('/v2/jobs', config)
    assert Wurk::API.serves?('/v10/jobs', config)
  end

  def test_the_version_prefix_is_the_one_the_app_serves_under
    assert_equal '/v1', Wurk::API::VERSION_PREFIX
    assert_equal ['v1'], Wurk::API::SUPPORTED_VERSIONS
  end

  # The same question one prefix out, for `Wurk::Web::Authorization` — it runs
  # before routing, so the engine's mount has not stripped anything yet and it
  # has to tell a machine-plane path from a dashboard one to know whose
  # read-only refusal this is.
  def test_the_engine_mount_prefix_is_the_one_the_engine_mounts_under
    assert_equal '/api', Wurk::API::ENGINE_MOUNT
  end

  def test_the_unstripped_form_claims_the_machine_plane
    assert Wurk::API.engine_serves?('/api/v1', config)
    assert Wurk::API.engine_serves?('/api/v1/jobs', config)
    assert Wurk::API.engine_serves?('/api/v2/jobs', config), 'an unknown version is still the machine plane'
  end

  def test_the_unstripped_form_leaves_the_dashboards_own_api_alone
    refute Wurk::API.engine_serves?('/api/stats', config)
    refute Wurk::API.engine_serves?('/api', config)
  end

  # Nested in the engine the machine plane lives under /api and nowhere else. A
  # path that looks like the version prefix on its own is some other engine
  # route, and handing it over would take it out from behind the read-only gate
  # it belongs to.
  def test_the_unstripped_form_requires_the_mount_prefix
    refute Wurk::API.engine_serves?('/v1', config)
    refute Wurk::API.engine_serves?('/v1/jobs', config)
    refute Wurk::API.engine_serves?('/apiary/v1', config)
  end

  def test_the_unstripped_form_claims_nothing_without_a_token
    refute Wurk::API.engine_serves?('/api/v1/jobs', bare_config)
  end

  private

  def config
    @config ||= Wurk::Configuration.new.tap { |cfg| cfg.api_token(TOKEN, scopes: %i[admin]) }
  end

  def bare_config = @bare_config ||= Wurk::Configuration.new
end
