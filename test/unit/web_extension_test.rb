# frozen_string_literal: true

require_relative '../test_helper'
require 'rack'
require 'cgi'
require 'wurk/web/extension'

# Pins the Web-extension renderer (#187): Sinatra-style route capture from
# `Ext.registered(app)`, the Action context (params/erb/redirect + the
# WebHelpers subset), and Renderer dispatch (render / redirect rewrite / 404 /
# unknown-ext nil / failing-registration 500 / asset lookup with traversal
# guard).
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

  def test_app_route_matches_multiple_methods_without_running_the_block
    app = Wurk::Web::Extension::App.new
    calls = 0
    block = proc do
      calls += 1
      route_params(:id)
    end
    app.route('GET', :post, '/items/:id', &block)

    %w[GET POST].each do |method|
      env = env_for(method, '').merge('PATH_INFO' => '/items/a%20b')
      action = app.match(env)

      assert_instance_of Wurk::Web::Extension::Action, action
      assert_same env, action.env
      assert_same block, action.block
      assert_equal({ id: 'a b' }, action.route_params)
      assert_equal 0, calls
    end
    assert_equal 'a b', app.match(env_for('GET', '').merge('PATH_INFO' => '/items/a%20b')).run
    assert_equal 1, calls
  end

  def test_app_match_returns_nil_for_method_and_path_misses
    app = Wurk::Web::Extension::App.new
    app.get('/items/:id') { 'matched' }

    assert_nil app.match(env_for('POST', '').merge('PATH_INFO' => '/items/1'))
    assert_nil app.match(env_for('GET', '').merge('PATH_INFO' => '/elsewhere'))
  end

  def test_app_match_uses_registration_order_and_run_accepts_an_explicit_block
    app = Wurk::Web::Extension::App.new
    app.get('/items/:id') { 'first' }
    app.get('/items/special') { 'second' }
    action = app.match(env_for('GET', '').merge('PATH_INFO' => '/items/special'))

    assert_equal 'first', action.run
    assert_equal 'override', action.run(proc { 'override' })
  end

  def test_verb_helpers_delegate_to_route
    app = Wurk::Web::Extension::App.new
    calls = []
    app.define_singleton_method(:route) { |*args, &block| calls << [args, block] }
    block = proc { 'ok' }
    %i[head get post put patch delete].each { |verb| app.public_send(verb, '/path', &block) }

    verbs = calls.map { |args, _| args.first }

    assert_equal %i[head get post put patch delete], verbs
    calls.each do |args, captured|
      assert_equal '/path', args.last
      assert_same block, captured
    end
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

  # A raising `registered(app)` used to re-run on every request (`||=` never
  # assigns past the raise) and its exception escaped Renderer into the host
  # Rack server.
  def test_failing_registration_is_a_500_on_every_request_and_runs_once
    calls = 0
    executions = 0
    reports = []
    handler = registration_report_handler(reports)
    broken = Module.new do
      define_singleton_method(:registered) do |app|
        calls += 1
        app.get('/listed') do
          executions += 1
          'should never render'
        end
        raise 'registration detonated'
      end
    end
    name = "broken-#{::Process.pid}-#{object_id}"
    begin
      Wurk::Web.config.register_extension(broken, name: name, tab: ["Broken #{name}"], index: ["#{name}/"])

      # `Wurk.configuration.error_handlers` is process-global and
      # `handle_exception` fans out to every handler on it, so this handler
      # keeps only this extension's registration reports and the count below
      # is exactly this extension's two registrations. — editor:tests[bot]
      Wurk::Test::GLOBAL_STATE_MUTEX.synchronize do
        Wurk.configuration.error_handlers << handler

        first_status, _headers, first_body = render_call('GET', '/listed', name: name)

        assert_equal 500, first_status
        assert_equal 'Extension render error (see server logs)', first_body
        refute_includes first_body, 'registration detonated', 'exception messages must stay server-side'

        second_status, _headers, second_body = render_call('GET', '/listed', name: name)

        assert_equal 500, second_status
        assert_equal 'Extension render error (see server logs)', second_body
        refute_includes second_body, 'registration detonated'
      ensure
        Wurk.configuration.error_handlers.delete(handler)
      end

      assert_equal 1, calls, 'registered(app) must run exactly once despite raising'
      assert_equal 0, executions
      assert_equal 2, reports.size
      assert_same reports.first[0], reports.last[0]
      reports.each do |error, context|
        assert_equal 'registration detonated', error.message
        assert_equal({ context: 'web-extension-registration' }, context)
      end
    ensure
      Wurk::Web.config.extensions.reject! { |e| e[:name] == name }
      Wurk::Web.config.tabs.delete("Broken #{name}")
    end
  end

  # `handle_exception` fans out to every handler on the process-global
  # `Wurk.configuration.error_handlers` list, so the registration handler must
  # drop a report that belongs to another error — a background thread
  # reporting while it is installed must not land in the collection the
  # failing-registration test counts. — editor:tests[bot]
  def test_registration_report_handler_ignores_unrelated_error_reports
    reports = []
    handler = registration_report_handler(reports)

    handler.call(StandardError.new('another test failed'), { context: 'some-other-context' }, nil)

    assert_empty reports

    error = StandardError.new('registration detonated')
    handler.call(error, { context: 'web-extension-registration' }, nil)

    assert_equal [[error, { context: 'web-extension-registration' }]], reports
  end

  def test_successful_registration_runs_exactly_once_across_requests
    calls = 0
    ext = Module.new do
      define_singleton_method(:registered) do |app|
        calls += 1
        app.helpers(Module.new { define_method(:greeting) { 'hello' } })
        app.route('GET', 'POST', '/once/:id') do
          erb '<%= greeting %> <%= h(route_params(:id)) %> <%= root_path %> <%= current_path %>'
        end
      end
    end
    name = "once-#{::Process.pid}-#{object_id}"
    begin
      Wurk::Web.config.register_extension(ext, name: name, tab: ["Once #{name}"], index: ["#{name}/"])

      env = env_for('GET', '').merge('PATH_INFO' => "/wurk/ext/#{name}/once/42")
      first_status, _headers, first_body = render_call('GET', '/once/42', name: name, env: env)

      assert_equal 200, first_status
      assert_equal "hello 42 /wurk/ext/#{name}/ once/42", first_body

      second_status, _headers, second_body = render_call('POST', '/once/43', name: name)

      assert_equal 200, second_status
      assert_equal "hello 43 /wurk/ext/#{name}/ once/43", second_body

      status, _headers, body = render_call('GET', '/once/44', name: name, embed: false)

      assert_equal 200, status
      assert_equal 'hello 44 /wurk/ once/44', body

      assert_equal 1, calls
    ensure
      Wurk::Web.config.extensions.reject! { |e| e[:name] == name }
      Wurk::Web.config.tabs.delete("Once #{name}")
    end
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

  # Collects only this extension's registration reports: `handle_exception`
  # hands every error to every handler on the global list, so an unrelated
  # report must not reach the collection the count assertions read.
  # — editor:tests[bot]
  def registration_report_handler(reports)
    proc do |error, context, _config|
      reports << [error, context] if context[:context].to_s == 'web-extension-registration'
    end
  end

  def render_call(method, subpath, query: '', embed: true, env: env_for(method, query), name: @name)
    Wurk::Web::Extension::Renderer.call(
      name: name, method: method, subpath: subpath, env: env, mount: '/wurk', embed: embed
    )
  end

  def env_for(method, query)
    {
      'REQUEST_METHOD' => method, 'QUERY_STRING' => query, 'rack.input' => ::StringIO.new,
      'rack.url_scheme' => 'http', 'HTTP_HOST' => 'example.org'
    }
  end
end
