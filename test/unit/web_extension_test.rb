# frozen_string_literal: true

require_relative '../test_helper'
require 'rack'
require 'cgi'
require 'wurk/web/extension'

# Pins the Web-extension renderer (#187): Sinatra-style route capture from
# `Ext.registered(app)`, the Action context (params/erb/redirect + the
# WebHelpers subset), and Renderer dispatch (render / redirect rewrite / 404 /
# unknown-ext nil / asset lookup with traversal guard).
#
# Registers into the process-global Wurk::Web.config under a per-test unique
# name and removes it in teardown, so parallel test classes never collide.
class WebExtensionTest < Wurk::Test::UnitCase
  parallelize_me!

  FIXTURE_DIR = File.expand_path('../fixtures/demo_ext', __dir__)

  # A synthetic extension exercising the surface real gems use
  # (sidekiq-unique-jobs shape: helpers + list/detail/delete routes). The
  # nested `def` inside `app.helpers` is the documented Sidekiq extension
  # idiom, and the route count is the fixture's whole point — both cops are
  # off for this faithful replica.
  # rubocop:disable-next Lint/NestedMethodDefinition
  module DemoExt
    def self.registered(app)
      app.helpers do
        def shout(text) = text.to_s.upcase
      end
      app.get '/hello' do
        @who = url_params('who') || 'world'
        erb :hello
      end
      app.get '/inline' do
        erb '<p><%= shout("hi") %>-<%= h("<x>") %></p>'
      end
      app.get '/items/:id' do
        erb '<p>item <%= h(route_params(:id)) %> of <%= h(params[:id]) %></p>'
      end
      app.get '/away' do
        redirect 'hello'
      end
      app.get '/external' do
        redirect 'https://example.com/elsewhere'
      end
      app.get '/boom' do
        raise 'kaboom'
      end
      app.post '/things' do
        erb '<p>made <%= h(url_params("name")) %></p>'
      end
      app.get '/data' do
        json(ok: true, id: url_params('id'))
      end
      app.get '/gone' do
        halt 404
        'unreachable'
      end
      app.get '/triple' do
        header 'X-Ext', 'yes'
        [201, { 'Content-Type' => 'text/csv' }, ['a,', 'b']]
      end
      app.get '/rendered' do
        render(:erb, '<i><%= shout("r") %></i>')
      end
      app.get '/haml' do
        render(:haml, '%i')
      end
      app.post '/reload' do
        reload_page
      end
      app.get '/off-site' do
        redirect_to 'https://example.com/elsewhere'
      end
      app.get '/to/:target' do
        redirect url_params('to')
      end
      app.get '/rooted' do
        redirect "#{root_path}hello"
      end
    end
  end

  def setup
    super
    @name = "demo-#{::Process.pid}-#{object_id}"
    Wurk::Web.config.register_extension(
      DemoExt,
      name: @name, tab: ["Demo #{@name}"], index: ["demo-#{@name}/"],
      root_dir: FIXTURE_DIR, asset_paths: [File.join(FIXTURE_DIR, 'assets')], cache_for: 123
    )
  end

  def teardown
    Wurk::Web.config.extensions.reject! { |e| e[:name] == @name }
    Wurk::Web.config.tabs.delete("Demo #{@name}")
  ensure
    super
  end

  # --- rendering ---------------------------------------------------------

  def test_renders_an_erb_view_from_root_dir_with_helpers_and_locale
    status, _headers, body = render_call('GET', '/hello', query: 'who=din')

    assert_equal 200, status
    # locales/en.yml translation + url_params-through-h, in document order.
    assert_match(%r{<h1>Hello from fixture</h1>.*<p class="who">din</p>}m, body)
    assert_includes body, 'href="/wurk/ext/' # root_path rewritten to the embed base
  end

  def test_renders_inline_template_with_extension_helpers
    status, _headers, body = render_call('GET', '/inline')

    assert_equal 200, status
    assert_equal '<p>HI-&lt;x&gt;</p>', body.strip
  end

  def test_route_params_are_extracted_and_merged_into_params
    _status, _headers, body = render_call('GET', '/items/42')

    assert_equal '<p>item 42 of 42</p>', body.strip
  end

  def test_post_routes_dispatch
    status, _headers, body = render_call('POST', '/things', query: 'name=widget')

    assert_equal 200, status
    assert_includes body, 'made widget'
  end

  # --- redirects -----------------------------------------------------------

  def test_relative_redirect_is_rewritten_to_the_embed_base
    status, headers, = render_call('GET', '/away')

    assert_equal 302, status
    assert_equal "/wurk/ext/#{@name}/hello", headers['Location']
  end

  # W14: `redirect` stays on this host like upstream's (which prepends
  # base_url); an off-site target collapses to the extension root.
  def test_absolute_off_site_redirect_collapses_to_the_ext_root
    _status, headers, = render_call('GET', '/external')

    assert_equal "/wurk/ext/#{@name}/", headers['Location']
  end

  def test_scheme_relative_and_disguised_redirects_collapse_to_the_ext_root
    ['//evil.com', '/\\evil.com', '\\\\evil.com', "\t//evil.com", "/\t/evil.com", 'javascript:alert(1)',
     'HTTPS://evil.com'].each do |target|
      _status, headers, = render_call('GET', '/to/x', query: "to=#{CGI.escape(target)}")

      assert_equal "/wurk/ext/#{@name}/", headers['Location'], target.inspect
    end
  end

  def test_same_origin_absolute_redirect_keeps_its_path
    _status, headers, = render_call('GET', '/to/x', query: "to=#{CGI.escape('http://example.org/hello')}")

    assert_equal "/wurk/ext/#{@name}/hello", headers['Location']
  end

  def test_root_path_redirect_is_not_prefixed_twice
    _status, headers, = render_call('GET', '/rooted')

    assert_equal "/wurk/ext/#{@name}/hello", headers['Location']
  end

  def test_standalone_scheme_relative_redirect_collapses_to_the_mount_root
    _status, headers, = render_call('GET', '/to/x', query: "to=#{CGI.escape('//evil.com')}", embed: false)

    assert_equal '/wurk/', headers['Location']
  end

  # `redirect_to` is upstream's explicit off-site redirect — served verbatim
  # standalone; embedded, the SPA's fetch can't follow it off-site.
  def test_redirect_to_passes_through_standalone_only
    _status, headers, = render_call('GET', '/off-site', embed: false)

    assert_equal 'https://example.com/elsewhere', headers['Location']
    _status, headers, = render_call('GET', '/off-site')

    assert_equal "/wurk/ext/#{@name}/", headers['Location']
  end

  # --- W9: the rest of upstream's Action surface ---------------------------

  def test_json_returns_an_application_json_response
    status, headers, body = render_call('GET', '/data', query: 'id=7')

    assert_equal 200, status
    assert_equal 'application/json', headers['Content-Type']
    assert_equal({ 'ok' => true, 'id' => '7' }, JSON.parse(body))
  end

  def test_halt_stops_the_route_with_that_status
    status, headers, body = render_call('GET', '/gone')

    assert_equal [404, 'text/plain', '404'], [status, headers['Content-Type'], body]
  end

  def test_route_returning_a_rack_triple_is_served_as_is
    status, headers, body = render_call('GET', '/triple')

    assert_equal [201, 'text/csv', 'a,b', 'yes'], [status, headers['Content-Type'], body, headers['X-Ext']]
  end

  def test_render_erb_matches_erb
    _status, _headers, body = render_call('GET', '/rendered')

    assert_equal '<i>R</i>', body
  end

  def test_render_with_another_engine_is_a_500
    assert_equal 500, render_call('GET', '/haml')[0]
  end

  def test_reload_page_embedded_returns_to_the_ext_index
    _status, headers, = render_call('POST', '/reload')

    assert_equal "/wurk/ext/#{@name}/demo-#{@name}/", headers['Location']
  end

  def test_reload_page_standalone_follows_a_same_origin_referer
    env = env_for('POST', '').merge('HTTP_REFERER' => 'http://example.org/wurk/demo/list?page=2')
    _status, headers, = render_call('POST', '/reload', embed: false, env: env)

    assert_equal '/wurk/demo/list?page=2', headers['Location']
  end

  def test_reload_page_standalone_ignores_a_cross_origin_referer
    env = env_for('POST', '').merge('HTTP_REFERER' => 'https://evil.com/phish')
    _status, headers, = render_call('POST', '/reload', embed: false, env: env)

    assert_equal '/wurk/', headers['Location']
  end

  # --- dispatch edges --------------------------------------------------------

  def test_unknown_route_is_404
    status, _headers, body = render_call('GET', '/nope')

    assert_equal 404, status
    assert_includes body, 'No GET route'
  end

  def test_unknown_extension_returns_nil_for_spa_fallthrough
    assert_nil Wurk::Web::Extension::Renderer.call(
      name: 'not-registered', method: 'GET', subpath: '/x', env: env_for('GET', ''), mount: '/wurk'
    )
  end

  def test_route_block_raise_is_a_500_not_an_exception
    status, _headers, body = render_call('GET', '/boom')

    assert_equal 500, status
    assert_includes body, 'Extension render error'
    refute_includes body, 'kaboom', 'exception messages must stay server-side'
  end

  # --- assets ----------------------------------------------------------------

  def test_asset_file_resolves_with_cache_for
    path, cache_for = Wurk::Web::Extension::Renderer.asset_file(@name, 'app.css')

    assert_equal File.join(FIXTURE_DIR, 'assets', 'app.css'), path
    assert_equal 123, cache_for
  end

  def test_asset_file_blocks_directory_traversal
    assert_nil Wurk::Web::Extension::Renderer.asset_file(@name, '../views/hello.erb')
  end

  def test_asset_file_missing_is_nil
    assert_nil Wurk::Web::Extension::Renderer.asset_file(@name, 'nope.css')
  end

  # --- route compilation ---------------------------------------------------

  def test_route_literals_with_regex_metacharacters_match_literally
    route = Wurk::Web::Extension::Route.new('/jobs/:jid.json')

    assert_equal({ jid: 'abc' }, route.match('/jobs/abc.json'))
    assert_nil route.match('/jobs/abcXjson')
  end

  def test_route_plus_sign_is_literal_not_a_quantifier
    route = Wurk::Web::Extension::Route.new('/foo+bar')

    refute_nil route.match('/foo+bar')
    assert_nil route.match('/foooo+bar')
  end

  # --- custom_tabs wiring ------------------------------------------------------

  def test_native_tab_path_with_trailing_slash_stays_out_of_custom_tabs
    label = "Native #{@name}"
    Wurk::Web.config.tabs[label] = 'cron/'

    assert_nil(Wurk::Web.config.custom_tabs.find { |t| t[:name] == label })
  ensure
    Wurk::Web.config.tabs.delete(label)
  end

  def test_custom_tabs_carry_the_extension_name
    tab = Wurk::Web.config.custom_tabs.find { |t| t[:name] == "Demo #{@name}" }

    assert_equal @name, tab[:ext_name]
    assert_equal "demo-#{@name}/", tab[:path]
  end

  private

  def render_call(method, subpath, query: '', embed: true, env: env_for(method, query))
    Wurk::Web::Extension::Renderer.call(
      name: @name, method: method, subpath: subpath, env: env, mount: '/wurk', embed: embed
    )
  end

  def env_for(method, query)
    {
      'REQUEST_METHOD' => method, 'QUERY_STRING' => query, 'rack.input' => ::StringIO.new,
      'rack.url_scheme' => 'http', 'HTTP_HOST' => 'example.org'
    }
  end
end
