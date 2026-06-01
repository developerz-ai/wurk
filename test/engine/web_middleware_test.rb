# frozen_string_literal: true

require_relative '../engine_test_helper'

# Verifies the `Wurk::Web.use` host-middleware hook (#41) wires through the
# engine, in front of the authorization hook. Mutates the global
# `Wurk::Web.config`, so cannot run in parallel with other classes that share
# the singleton.
class WebMiddlewareTest < Wurk::Test::EngineCase
  # Stand-in for a host-app auth middleware (Devise/Warden/Sorcery): 401s
  # unless the request carries an authenticated user. The block decides who
  # counts as authenticated — exactly how a real integration reads
  # `env['warden'].user` or a session.
  class RequireAuth
    UNAUTHORIZED = [401, { 'Content-Type' => 'text/plain' }, ['Unauthorized']].freeze

    def initialize(app, &authenticated)
      @app = app
      @authenticated = authenticated
    end

    def call(env)
      return UNAUTHORIZED.dup unless @authenticated.call(env)

      @app.call(env)
    end
  end

  # Records the order it was wrapped in, so we can prove the chain nests
  # outermost-first like Rack::Builder.
  class Tag
    def initialize(app, marks, name)
      @app = app
      @marks = marks
      @name = name
    end

    def call(env)
      @marks << @name
      @app.call(env)
    end
  end

  def setup
    super
    Wurk::Web.reset_config!
  end

  def teardown
    Wurk::Web.reset_config!
    super
  end

  def test_no_host_middleware_by_default
    get '/wurk/api/stats'

    assert_equal 200, last_response.status
  end

  # The acceptance criterion: 401 by default, 200 once the host wires an
  # authenticated user.
  def test_use_gates_dashboard_until_authenticated
    Wurk::Web.use(RequireAuth) { |env| env['HTTP_X_USER'] == 'admin' }

    get '/wurk/api/stats'

    assert_equal 401, last_response.status
    assert_equal 'Unauthorized', last_response.body

    get '/wurk/api/stats', {}, { 'HTTP_X_USER' => 'admin' }

    assert_equal 200, last_response.status
  end

  def test_use_is_available_inside_configure_block
    Wurk::Web.configure do |c|
      c.use(RequireAuth) { |_env| false }
    end

    get '/wurk/api/stats'

    assert_equal 401, last_response.status
  end

  def test_use_passes_args_through_to_middleware
    Wurk::Web.use(Rack::Auth::Basic, 'Wurk') do |user, pass|
      user == 'admin' && pass == 's3cret'
    end

    get '/wurk/api/stats'

    assert_equal 401, last_response.status

    authorize 'admin', 's3cret'
    get '/wurk/api/stats'

    assert_equal 200, last_response.status
  end

  def test_multiple_middlewares_chain_outermost_first
    marks = []
    Wurk::Web.use(Tag, marks, 'outer')
    Wurk::Web.use(Tag, marks, 'inner')

    get '/wurk/api/stats'

    assert_equal 200, last_response.status
    assert_equal %w[outer inner], marks
  end

  # Host middleware runs before the authorization hook, so the hook can read
  # state the host middleware set on env.
  def test_host_middleware_runs_before_authorization_hook
    Wurk::Web.use(RequireAuth) { |env| env['HTTP_X_USER'] == 'admin' }
    seen = nil
    Wurk::Web.configure do |c|
      c.authorization do |env, _, _|
        seen = env['HTTP_X_USER']
        true
      end
    end

    get '/wurk/api/stats', {}, { 'HTTP_X_USER' => 'admin' }

    assert_equal 200, last_response.status
    assert_equal 'admin', seen
  end

  def test_middlewares_reader_records_registrations
    Wurk::Web.use(RequireAuth)

    assert_equal 1, Wurk::Web.config.middlewares.length
    assert_equal RequireAuth, Wurk::Web.config.middlewares.first.first
  end
end
