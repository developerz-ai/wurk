# frozen_string_literal: true

require_relative '../engine_test_helper'

# Verifies the Rack-level authorization hook (sidekiq-ent §9.2) wires through
# the engine middleware. Mutates the global `Wurk::Web.config`, so cannot run
# in parallel with other classes that share the same singleton.
class WebAuthorizationTest < Wurk::Test::EngineCase
  def setup
    super
    Wurk::Web.reset_config!
  end

  def teardown
    Wurk::Web.reset_config!
    super
  end

  def test_default_allows_request_through
    get '/wurk/api/stats'

    assert_equal 200, last_response.status
  end

  def test_falsey_authorization_returns_403
    Wurk::Web.configure { |c| c.authorization { |_, _, _| false } }

    get '/wurk/api/stats'

    assert_equal 403, last_response.status
    assert_equal 'Forbidden', last_response.body
  end

  def test_truthy_authorization_allows_through
    Wurk::Web.configure { |c| c.authorization { |_, _, _| true } }

    get '/wurk/api/stats'

    assert_equal 200, last_response.status
  end

  def test_block_receives_method_and_path
    captured = nil
    Wurk::Web.configure do |c|
      c.authorization do |_, method, path|
        captured = [method, path]
        true
      end
    end

    get '/wurk/api/queues'

    refute_nil captured
    assert_equal 'GET', captured[0]
  end

  def test_method_specific_authorization
    Wurk::Web.configure do |c|
      c.authorization { |_, method, _| method == 'GET' }
    end

    get '/wurk/api/stats'

    assert_equal 200, last_response.status

    post '/wurk/api/cron/no-such/pause'

    assert_equal 403, last_response.status
  end

  # --- Read-only mode ---------------------------------------------------
  #
  # The SPA branches on `read_only` directly, so /api/meta must carry a real
  # JSON boolean — `assert_same true/false` rather than assert/refute, which a
  # dropped key (nil) or a truthy non-boolean would still satisfy.

  def test_read_only_blocks_mutating_endpoint
    Wurk::Web.configure { |c| c.read_only = true }

    post '/wurk/api/cron/no-such/pause'

    assert_equal 403, last_response.status
    assert_equal 'Read-only mode', last_response.body
  end

  def test_read_only_allows_read_endpoint
    Wurk::Web.configure { |c| c.read_only = true }

    get '/wurk/api/stats'

    assert_equal 200, last_response.status
  end

  def test_meta_reports_read_write_by_default
    get '/wurk/api/meta'

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)

    assert_same false, body['read_only']
    assert_nil body['read_only_message']
  end

  # The SPA shows the running gem version next to the nav wordmark; meta carries
  # it so the dashboard never has to guess from the asset manifest.
  def test_meta_reports_the_gem_version
    get '/wurk/api/meta'

    assert_equal 200, last_response.status
    assert_equal Wurk::VERSION, JSON.parse(last_response.body)['version']
  end

  def test_meta_reports_read_only_when_enabled
    Wurk::Web.configure { |c| c.read_only = true }

    get '/wurk/api/meta'

    assert_equal 200, last_response.status
    assert_same true, JSON.parse(last_response.body)['read_only']
  end

  # Per-request read-only: a viewer role (authorization hook permits GET but
  # denies mutations) must surface read_only=true so the SPA hides destructive
  # actions — even with the global read-only mode off.
  def test_meta_reports_read_only_for_a_view_only_authorization
    Wurk::Web.configure { |c| c.authorization { |_, method, _| method == 'GET' } }

    get '/wurk/api/meta'

    assert_equal 200, last_response.status
    assert_same true, JSON.parse(last_response.body)['read_only']
  end

  # An authorization hook that permits mutations (e.g. an admin role) keeps
  # read_only false so the SPA shows the actions.
  def test_meta_reports_read_write_for_a_mutating_authorization
    Wurk::Web.configure { |c| c.authorization { |_, _, _| true } }

    get '/wurk/api/meta'

    assert_equal 200, last_response.status
    assert_same false, JSON.parse(last_response.body)['read_only']
  end

  # A path-sensitive hook (permits the current /api/meta path but denies real
  # mutating routes) must still report read_only=true. The probe has to ask
  # about a canonical mutating path, not the GET request's own /api/meta path —
  # otherwise the SPA shows actions that the Authorization middleware then 403s.
  def test_meta_reports_read_only_for_a_path_sensitive_authorization
    Wurk::Web.configure do |c|
      c.authorization { |_, _, path| path == '/api/meta' }
    end

    get '/wurk/api/meta'

    assert_equal 200, last_response.status
    assert_same true, JSON.parse(last_response.body)['read_only']
  end

  def test_meta_includes_read_only_message_when_set
    Wurk::Web.configure do |c|
      c.read_only = true
      c.read_only_message = 'This is a public demo — actions are disabled.'
    end

    get '/wurk/api/meta'

    assert_equal 200, last_response.status
    assert_equal 'This is a public demo — actions are disabled.',
                 JSON.parse(last_response.body)['read_only_message']
  end

  def test_meta_custom_tabs_empty_by_default
    get '/wurk/api/meta'

    assert_equal [], JSON.parse(last_response.body)['custom_tabs']
  end

  # A third-party extension registering a tab surfaces it in /api/meta, which
  # the SPA nav reads (spec §25.2), including the ext_name the Extension page
  # uses to fetch the server-rendered view (#187).
  def test_meta_exposes_registered_custom_tabs
    Wurk::Web.configure { |c| c.register_extension(Object, name: 'locks', tab: 'Locks', index: 'locks') }

    get '/wurk/api/meta'

    assert_equal 200, last_response.status
    assert_includes JSON.parse(last_response.body)['custom_tabs'],
                    { 'name' => 'Locks', 'path' => 'locks', 'ext_name' => 'locks' }
  end
end
