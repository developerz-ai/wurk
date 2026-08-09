# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'json'

# Slice 07, task 48 — the three mounts, proven to be one implementation:
#
#   1. nested in the engine at `<mount>/api/v1`, conditional on a token
#      (config/routes.rb)
#   2. mounted on its own path by the host — `mount Wurk::API => '/wurk-api'`
#      (test/dummy/config/routes.rb), dashboard untouched
#   3. standalone Rack, no Rails — `run Wurk::API` in any config.ru
#
# Each has to serve the same routes and emit URLs correct for where it was
# mounted: nothing in lib/wurk/api may hardcode a prefix. The auth gate itself
# is pinned in api_v1_auth_test.rb; this file speaks only about mounting.
#
# Registers a token on the process-wide `Wurk.configuration` — the same global
# registry the whole engine suite shares — so, like api_v1_auth_test.rb, this
# class does not declare `parallelize_me!` and serializes its own methods
# through GLOBAL_STATE_MUTEX.
class ApiMountModesTest < Wurk::Test::EngineCase
  TOKEN = 'engine-api-mount-modes-token-cccc'

  # Where each mode answers, and the URL prefix it must emit from there. The
  # dummy host mounts the engine twice (/wurk and /sidekiq) and Wurk::API once
  # on its own path; standalone is the module served directly, prefix-free.
  ENGINE_MOUNT     = '/wurk/api'
  ALT_ENGINE_MOUNT = '/sidekiq/api'
  SEPARATE_MOUNT   = '/wurk-api'
  STANDALONE_MOUNT = ''

  RAILS_MOUNTS = [ENGINE_MOUNT, ALT_ENGINE_MOUNT, SEPARATE_MOUNT].freeze

  def run(*)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize { super }
  end

  def setup
    super
    Wurk.configuration.api_token(TOKEN, scopes: %i[admin])
  end

  def teardown
    Wurk.configuration.api_tokens.delete(TOKEN)
  ensure
    super
  end

  # --- one implementation, three addresses -----------------------------

  def test_every_mount_serves_the_discovery_document
    (RAILS_MOUNTS + [STANDALONE_MOUNT]).each do |mount|
      body = json(get_at(mount, '/v1'))

      assert_equal 200, response_at(mount).status, "#{mount} must serve the version root"
      assert_equal 'v1', body['api_version'], mount
      assert_equal Wurk::VERSION, body['wurk_version'], mount
    end
  end

  # The mount-agnostic contract: the URL a client is handed has to point back
  # at the prefix it actually reached the API through, never a baked-in /wurk.
  def test_every_mount_emits_urls_for_its_own_prefix
    (RAILS_MOUNTS + [STANDALONE_MOUNT]).each do |mount|
      assert_equal "#{mount}/v1", json(get_at(mount, '/v1'))['url'], mount
    end
  end

  def test_every_mount_serves_the_same_route_table
    (RAILS_MOUNTS + [STANDALONE_MOUNT]).each do |mount|
      assert_equal 200, get_at(mount, '/v1/queues').status, "#{mount} must route past the version root"
      assert_includes json(get_at(mount, '/v1/queues')), 'queues', mount

      missed = get_at(mount, '/v1/nope')

      assert_equal 404, missed.status, mount
      assert_equal 'not_found', json(missed)['type'], mount
    end
  end

  # A version this build does not serve is the app's refusal to make, and it
  # has to read the same from all three mounts: a problem document naming the
  # versions that do exist, never a bare Rails route miss that leaves a client
  # guessing whether it got the version wrong or the address.
  def test_every_mount_refuses_an_unsupported_version_by_name
    (RAILS_MOUNTS + [STANDALONE_MOUNT]).each do |mount|
      refused = get_at(mount, '/v2/jobs')

      assert_equal 404, refused.status, mount
      assert_equal 'application/problem+json', refused.content_type, mount
      assert_equal 'unsupported_api_version', json(refused)['type'], mount
      assert_equal ['v1'], json(refused)['supported_versions'], mount
    end
  end

  def test_every_mount_reports_the_same_allowed_methods
    (RAILS_MOUNTS + [STANDALONE_MOUNT]).each do |mount|
      refused = post_at(mount, '/v1')

      assert_equal 405, refused.status, mount
      assert_equal 'GET, HEAD', refused.headers['allow'], mount
    end
  end

  # --- mode 1: nested in the engine ------------------------------------

  # The additive invariant, at the mount rather than in the app: with no token
  # the constraint fails, Rails falls through, and the path answers exactly as
  # it did before — a route miss for a machine client, the SPA shell for a
  # browser. Never a bearer challenge advertising a surface that is switched
  # off.
  def test_the_engine_nested_mount_does_not_exist_without_a_token
    Wurk.configuration.api_tokens.delete(TOKEN)

    response = rails.get("#{ENGINE_MOUNT}/v1", {}, 'HTTP_ACCEPT' => 'application/json')

    assert_equal 404, response.status
    refute_equal 'application/problem+json', response.content_type
    refute response.headers.key?('www-authenticate'), 'a switched-off API must not challenge for a token'
  end

  # The machine plane is nested under the same /api prefix the dashboard's own
  # JSON API owns. Those routes are declared first and must keep matching.
  def test_the_dashboards_own_api_still_wins_under_the_engine_mount
    response = rails.get("#{ENGINE_MOUNT}/queues", {}, 'HTTP_ACCEPT' => 'application/json')

    assert_equal 200, response.status
    assert_kind_of Array, JSON.parse(response.body), 'the SPA-shaped payload, not the machine plane'
  end

  # ...and a path that misses them stays a Rails route miss. Claiming the whole
  # /api prefix would answer a mistyped dashboard path with a 401 challenge for
  # a route that was never part of this contract.
  def test_a_dashboard_api_miss_is_not_answered_by_the_machine_plane
    response = rails.get("#{ENGINE_MOUNT}/queuez", {}, 'HTTP_ACCEPT' => 'application/json')

    assert_equal 404, response.status
    refute_equal 'application/problem+json', response.content_type
  end

  # --- mode 2: mounted separately --------------------------------------

  def test_the_separate_mount_leaves_the_dashboard_alone
    assert_equal 200, rails.get('/wurk/').status
    assert_includes rails.last_response.body, '<div id="wurk-root"', 'the dashboard shell, unchanged'
  end

  # Rails matches a mounted app by bare string prefix, so an engine at /wurk
  # claims every /wurk-api path too. It only *answers* what its own routes
  # match — a JSON request misses them and cascades back out — but the SPA
  # catch-all matches any html-format path, so with the engine declared first a
  # browser pointed at the machine API is handed the dashboard shell instead.
  # Hence the declaration order in test/dummy/config/routes.rb.
  def test_the_separate_mount_outranks_an_engine_whose_prefix_it_extends
    response = rails.get("#{SEPARATE_MOUNT}/v1")

    assert_equal 200, response.status
    assert_equal 'v1', json(response)['api_version'], 'the machine API, not the dashboard shell'
  end

  private

  # Rack::Test::Methods binds one session to `app`; three of these mounts are
  # reached through the host app and the fourth is the bare module, so each
  # gets its own explicit session instead.
  def rails
    @rails ||= ::Rack::Test::Session.new(::Rails.application).tap { |s| s.header('Authorization', "Bearer #{TOKEN}") }
  end

  def standalone
    @standalone ||= ::Rack::Test::Session.new(::Wurk::API).tap { |s| s.header('Authorization', "Bearer #{TOKEN}") }
  end

  def session_for(mount) = mount == STANDALONE_MOUNT ? standalone : rails

  def get_at(mount, path)
    session_for(mount).get("#{mount}#{path}", {}, 'HTTP_ACCEPT' => 'application/json')
  end

  def post_at(mount, path)
    session_for(mount).post("#{mount}#{path}", {}, 'HTTP_ACCEPT' => 'application/json')
  end

  def response_at(mount) = session_for(mount).last_response

  def json(response) = ::JSON.parse(response.body)
end
