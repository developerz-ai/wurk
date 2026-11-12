# frozen_string_literal: true

require_relative '../engine_test_helper'

# The served SPA shell under host setups the dummy app does not configure by
# default: a strict Content-Security-Policy with a nonce (#101 W1), and a host
# mounted under a path prefix (RAILS_RELATIVE_URL_ROOT or a proxy that sets
# SCRIPT_NAME, #101 W2).
#
# Mutates the global Rails env_config and Wurk::Web.config, so cannot run in
# parallel with other classes sharing them. Asserts against the real built
# shell for the reason spelled out in DashboardRoutesTest.
class DashboardShellTest < Wurk::Test::EngineCase
  INDEX = ::Wurk::Engine.root.join('vendor', 'assets', 'dashboard', 'index.html')
  NONCE = 'r4nd0mN0nce'
  CSP_KEYS = %w[
    action_dispatch.content_security_policy
    action_dispatch.content_security_policy_nonce_generator
    action_dispatch.content_security_policy_nonce_directives
  ].freeze

  def setup
    super
    Wurk::Web.reset_config!
    skip 'dashboard build missing (run `bin/rake frontend:build`)' unless INDEX.exist?
  end

  def teardown
    Wurk::Web.reset_config!
    super
  end

  def test_strict_csp_nonce_reaches_every_script_in_the_shell
    Wurk::Web.configure do |c|
      c.default_theme = 'dark'
      c.translations = { 'en' => { 'nav' => { 'dashboard' => 'Home' } } }
    end

    with_strict_csp { get '/wurk' }

    assert_equal 200, last_response.status
    assert_includes last_response.headers['Content-Security-Policy'], "'nonce-#{NONCE}'"
    scripts = last_response.body.scan(/<script\b[^>]*>/)

    assert_operator scripts.size, :>=, 4, scripts.inspect # pre-paint, theme, mount base, module (+ i18n JSON)
    scripts.each { |tag| assert_includes tag, %(nonce="#{NONCE}") }
    assert_includes last_response.body, %(<script nonce="#{NONCE}">window.__WURK_BASE__ = "/wurk";</script>)
  end

  def test_no_nonce_attribute_without_a_nonce_generator
    get '/wurk'

    assert_equal 200, last_response.status
    refute_includes last_response.body, 'nonce='
  end

  def test_asset_urls_are_absolute_under_the_asset_mount
    get '/wurk'

    assert_equal 200, last_response.status
    refute_match(%r{(?:src|href)="\./}, last_response.body)
    assert_match(%r{<script type="module" crossorigin src="/wurk-assets/assets/index-[^"]+\.js"}, last_response.body)
    assert_includes last_response.body, 'href="/wurk-assets/favicon-32.png"'
  end

  # The host app lives under /app; AssetMount runs in the host's stack, so the
  # assets answer at /app/wurk-assets, and the shell must point there.
  def test_sub_path_mount_prefixes_every_asset_url_and_the_assets_load
    get '/wurk', {}, 'SCRIPT_NAME' => '/app'

    assert_equal 200, last_response.status
    body = last_response.body

    assert_includes body, 'window.__WURK_BASE__ = "/app/wurk";'
    urls = body.scan(/(?:src|href)="([^"]+)"/).flatten

    refute_empty urls
    urls.each { |url| assert url.start_with?('/app/wurk-assets/'), "#{url} is outside /app/wurk-assets/" }

    entry = urls.find { |u| u.end_with?('.js') }
    get entry.delete_prefix('/app'), {}, 'SCRIPT_NAME' => '/app'

    assert_equal 200, last_response.status
  end

  private

  def with_strict_csp
    env = ::Rails.application.env_config
    saved = CSP_KEYS.to_h { |k| [k, env[k]] }
    env[CSP_KEYS[0]] = ::ActionDispatch::ContentSecurityPolicy.new do |p|
      p.default_src :self
      p.script_src :self
    end
    env[CSP_KEYS[1]] = ->(_request) { NONCE }
    env[CSP_KEYS[2]] = %w[script-src]
    yield
  ensure
    saved.each { |k, v| v.nil? ? env.delete(k) : env[k] = v }
  end
end
