# frozen_string_literal: true

require_relative '../test_helper'
# The extension renderer builds a `Rack::Request` (lib/wurk/web/extension.rb),
# and this suite is Rails-free: without rack loaded the render raises and every
# extension route answers the render-error 500 instead of the route's own.
require 'rack'
require 'stringio'

# Parity oracle for the dashboard's authorization and read-only gates.
#
# Upstream evidence exists for this plane. Sidekiq Enterprise gates
# `mount Sidekiq::Web` with an `authorization` block (docs/target/sidekiq-ent.md
# §9.2 — "Block returns truthy → request proceeds; falsey → `403`"), and the
# wiki pins the order the host's own Rack middleware runs in
# (docs/wiki/The-Dashboard.md — "Middleware registered here runs **before** the
# authorization hook below"). Wurk ships that surface in the free gem, so the
# gates are the same gates.
#
# Sources enforced:
# - docs/target/sidekiq-ent.md L759 — a falsey authorization block answers 403.
# - docs/dashboard.md L71-L74 — the falsey answer is 403, and the hook's `path`
#   is engine-relative, not the host's absolute path.
# - docs/dashboard.md L78-L80 — read-only mode 403s every mutating request.
# - docs/dashboard.md L22-L24 — host middleware runs first (outermost), so the
#   authorization hook sees the env it populated.
#
# The dashboard itself is Rails-only in Wurk and this suite is Rails-free, so
# the gates are driven through the upstream class-level Rack entry,
# `Sidekiq::Web.call(env)`: the standalone mount, which Wurk keeps behind the
# same authorization and read-only gates, in the same order, in front of the
# extensions dispatcher. A registered extension route stands in for the
# dashboard's own pages.
#
# `Wurk::Web.config` is a process-global singleton: every test resets it and
# restores `WURK_WEB_READ_ONLY`, which the config re-reads when it is rebuilt.
class WebDashboardParityTest < Wurk::Test::UnitCase
  # The dashboard's own pages live in the Rails engine; a registered extension
  # route is the same plane's public surface in a Rails-free process.
  module ProbeExtension
    def self.registered(app)
      app.get('/probe') { 'probe body' }
    end
  end

  # Stands in for a host's Devise/Warden gate: it populates the env the
  # authorization hook is documented to read.
  class WardenStub
    def initialize(app, order)
      @app = app
      @order = order
    end

    def call(env)
      @order << :middleware
      env['warden'] = 'admin'
      @app.call(env)
    end
  end

  def setup
    super
    @read_only_env = ENV.fetch('WURK_WEB_READ_ONLY', nil)
    ENV.delete('WURK_WEB_READ_ONLY')
    Wurk::Web.reset_config!
    register_probe
  end

  def teardown
    ENV['WURK_WEB_READ_ONLY'] = @read_only_env
    Wurk::Web.reset_config!
    super
  end

  # --- The authorization hook ----------------------------------------------

  # The hook's verdict is the gate: a truthy answer lets the request proceed,
  # a falsey one short-circuits it to 403 before the dashboard is reached.
  def test_a_falsey_authorization_block_refuses_the_request
    Sidekiq::Web.configure { |c| c.authorization { |_env, _method, _path| false } }

    status, headers, body = Sidekiq::Web.call(env_for('GET', '/probe'))

    assert_equal 403, status
    assert_equal 'Forbidden', body.join
    assert_equal 'text/plain', content_type(headers)

    Sidekiq::Web.configure { |c| c.authorization { |_env, _method, _path| true } }

    status, = Sidekiq::Web.call(env_for('GET', '/probe'))

    assert_equal 200, status, 'a truthy answer did not let the request proceed'
  end

  # The hook's `path` is engine-relative, so a block written for Sidekiq keeps
  # working whatever prefix the dashboard is mounted at.
  def test_the_authorization_block_receives_the_mount_relative_path
    seen = nil
    Sidekiq::Web.configure do |c|
      c.authorization do |_env, method, path|
        seen = [method, path]
        true
      end
    end

    Sidekiq::Web.call(env_for('GET', '/api/stats', script_name: '/wurk'))

    assert_equal ['GET', '/api/stats'], seen
  end

  # --- Read-only mode ------------------------------------------------------

  # A viewer-only deployment answers reads and refuses every mutation, at the
  # middleware layer — the SPA hiding its destructive buttons is the other half
  # of the same rule, not the gate itself.
  def test_read_only_refuses_every_mutating_request
    ENV['WURK_WEB_READ_ONLY'] = '1'
    Wurk::Web.reset_config!
    register_probe

    %w[POST PUT PATCH DELETE].each do |method|
      status, _headers, body = Sidekiq::Web.call(env_for(method, '/probe'))

      assert_equal 403, status, "#{method} was not refused"
      assert_equal 'Read-only mode', body.join
    end

    status, = Sidekiq::Web.call(env_for('GET', '/probe'))

    assert_equal 200, status, 'read-only mode must still answer reads'
  end

  # --- Composition ---------------------------------------------------------

  # The two hooks compose: the host's middleware is outermost, so by the time
  # the authorization block runs, the env it reads is already populated.
  def test_host_middleware_runs_before_the_authorization_hook
    order = []
    Sidekiq::Web.use(WardenStub, order)
    Sidekiq::Web.configure do |c|
      c.authorization do |env, _method, _path|
        order << :authorization
        env['warden'] == 'admin'
      end
    end

    status, = Sidekiq::Web.call(env_for('GET', '/probe'))

    assert_equal 200, status
    assert_equal %i[middleware authorization], order
  end

  private

  def register_probe
    Sidekiq::Web.register(ProbeExtension, name: 'probe', tab: 'Probe', index: 'probe')
  end

  # Rack does not settle on one casing for a header name, so the refusal's
  # content type is looked up rather than spelled one way.
  def content_type(headers)
    headers.find { |name, _value| name.casecmp?('content-type') }&.last
  end

  def env_for(method, path, script_name: '')
    {
      'REQUEST_METHOD' => method,
      'PATH_INFO' => path,
      'SCRIPT_NAME' => script_name,
      'QUERY_STRING' => '',
      'rack.input' => StringIO.new,
      'rack.errors' => StringIO.new
    }
  end
end
