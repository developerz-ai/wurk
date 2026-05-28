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
    assert_equal false, JSON.parse(last_response.body)['read_only']
  end

  def test_meta_reports_read_only_when_enabled
    Wurk::Web.configure { |c| c.read_only = true }

    get '/wurk/api/meta'

    assert_equal 200, last_response.status
    assert_equal true, JSON.parse(last_response.body)['read_only']
  end
end
