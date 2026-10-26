# frozen_string_literal: true

require_relative '../engine_test_helper'

# Drives the Web-extension endpoints (#187) against the booted dummy app:
# `GET/POST /wurk/ext/:name/*` renders the registered extension's route and
# `GET /wurk/ext-assets/:name/*` serves its asset_paths. Registers a synthetic
# extension under a per-test unique name and removes it in teardown.
#
# Mutates the process-wide `Wurk::Web.config`, so — like
# web_authorization_test.rb — this class does not declare `parallelize_me!`.
# Minitest would run the methods in threads, and a concurrent
# `register_extension` inserts into the shared `tabs` Hash while a sibling
# request iterates it (`/api/meta` → `custom_tabs`), which raises "can't add
# a new key into hash during iteration" inside a test. — editor:router[bot]
class ExtensionsTest < Wurk::Test::EngineCase
  FIXTURE_DIR = File.expand_path('../fixtures/demo_ext', __dir__)

  # Serializes against the other classes that mutate the same singletons
  # (api_read_only_test.rb's pattern). — editor:router[bot]
  def run(*)
    Wurk::Test::GLOBAL_STATE_MUTEX.synchronize { super }
  end

  module EngineExt
    def self.registered(app)
      app.route('GET', 'POST', '/routed/:id') do
        erb '<p>routed <%= h(route_params(:id)) %> / <%= h(params[:id]) %></p>'
      end
      app.get '/list' do
        erb '<table class="ext-table"><tr><td><%= h(url_params("q") || "all") %></td></tr></table>'
      end
      app.get '/list/clear' do
        redirect 'list'
      end
      app.post '/list' do
        erb '<p>posted</p>'
      end
      app.put '/list' do
        erb '<p>put</p>'
      end
      app.delete '/list' do
        erb '<p>deleted</p>'
      end
      app.get '/stats.json' do
        header 'X-Ext', 'yes'
        json(count: 3)
      end
      app.get '/missing' do
        halt 404
      end
    end
  end

  def setup
    super
    @name = "engext-#{::Process.pid}-#{object_id}"
    ::Wurk::Web.config.register_extension(
      EngineExt,
      name: @name, tab: ["Eng #{@name}"], index: ["eng-#{@name}/"],
      asset_paths: [File.join(FIXTURE_DIR, 'assets')], cache_for: 60
    )
  end

  def teardown
    ::Wurk::Web.config.extensions.reject! { |e| e[:name] == @name }
    ::Wurk::Web.config.tabs.delete("Eng #{@name}")
  ensure
    super
  end

  def test_renders_a_registered_extension_route
    get "/wurk/ext/#{@name}/list?q=needle"

    assert_ok
    assert_includes last_response.body, '<td>needle</td>'
    assert_includes last_response.content_type, 'text/html'
  end

  def test_route_dsl_dispatches_first_and_repeated_get_requests
    %w[first second].each do |id|
      get "/wurk/ext/#{@name}/routed/#{id}"

      assert_ok
      assert_equal "<p>routed #{id} / #{id}</p>", last_response.body
    end
  end

  def test_route_dsl_dispatches_first_and_repeated_same_origin_posts
    %w[first second].each do |id|
      post "/wurk/ext/#{@name}/routed/#{id}", {}, { 'HTTP_SEC_FETCH_SITE' => 'same-origin' }

      assert_ok
      assert_equal "<p>routed #{id} / #{id}</p>", last_response.body
    end
  end

  def test_raising_registration_is_cached_and_never_executes_partial_routes
    calls = 0
    executions = 0
    broken = Module.new do
      define_singleton_method(:registered) do |app|
        calls += 1
        app.route('GET', 'POST', '/partial/:id') do
          executions += 1
          'partial route'
        end
        raise 'private registration details'
      end
    end
    name = "broken-engext-#{::Process.pid}-#{object_id}"
    begin
      Wurk::Web.config.register_extension(broken, name: name, tab: ["Broken #{name}"], index: ["#{name}/"])
      2.times do
        get "/wurk/ext/#{name}/partial/42"

        assert_equal 500, last_response.status
        assert_equal 'Extension render error (see server logs)', last_response.body
        refute_includes last_response.body, 'private registration details'
      end
      assert_equal 1, calls
      assert_equal 0, executions
    ensure
      Wurk::Web.config.extensions.reject! { |ext| ext[:name] == name }
      Wurk::Web.config.tabs.delete("Broken #{name}")
    end
  end

  def test_extension_redirect_stays_under_the_embed_base
    get "/wurk/ext/#{@name}/list/clear"

    assert_equal 302, last_response.status
    assert_includes last_response.headers['Location'], "/wurk/ext/#{@name}/list"
  end

  # W9: the controller serves the extension's own content type instead of
  # forcing HTML, and passes its headers through.
  def test_json_route_is_served_as_json
    get "/wurk/ext/#{@name}/stats.json"

    assert_ok
    assert_includes last_response.content_type, 'application/json'
    assert_equal({ 'count' => 3 }, JSON.parse(last_response.body))
    assert_equal 'yes', last_response.headers['X-Ext']
  end

  def test_halt_404_is_a_plain_text_404
    get "/wurk/ext/#{@name}/missing"

    assert_equal 404, last_response.status
    assert_includes last_response.content_type, 'text/plain'
    assert_equal '404', last_response.body
  end

  def test_unknown_route_renders_404_body
    get "/wurk/ext/#{@name}/nope"

    assert_equal 404, last_response.status
  end

  def test_unregistered_name_falls_through_to_the_spa_shell
    get '/wurk/ext/some-client-tab/'

    assert_ok
    assert_includes last_response.body, 'wurk-root' # the SPA shell, not a 404
  end

  def test_post_route_dispatches_same_origin
    post "/wurk/ext/#{@name}/list", {}, { 'HTTP_SEC_FETCH_SITE' => 'same-origin' }

    assert_ok
    assert_includes last_response.body, 'posted'
  end

  def test_cross_site_post_is_forbidden
    post "/wurk/ext/#{@name}/list", {}, { 'HTTP_SEC_FETCH_SITE' => 'cross-site' }

    assert_equal 403, last_response.status
  end

  def test_post_without_fetch_metadata_is_forbidden
    post "/wurk/ext/#{@name}/list"

    assert_equal 403, last_response.status
  end

  def test_put_routes_dispatch_same_origin
    put "/wurk/ext/#{@name}/list", {}, { 'HTTP_SEC_FETCH_SITE' => 'same-origin' }

    assert_ok
    assert_includes last_response.body, 'put'
  end

  def test_delete_routes_dispatch_same_origin
    delete "/wurk/ext/#{@name}/list", {}, { 'HTTP_SEC_FETCH_SITE' => 'same-origin' }

    assert_ok
    assert_includes last_response.body, 'deleted'
  end

  def test_serves_extension_assets_with_cache_control
    get "/wurk/ext-assets/#{@name}/app.css"

    assert_ok
    assert_includes last_response.body, 'rebeccapurple'
    assert_includes last_response.headers['Cache-Control'], 'max-age=60'
  end

  def test_asset_traversal_is_not_found
    get "/wurk/ext-assets/#{@name}/..%2Fviews%2Fhello.erb"

    assert_equal 404, last_response.status
  end

  def test_meta_custom_tabs_include_ext_name
    get '/wurk/api/meta'

    assert_ok
    tab = json_body[:custom_tabs].find { |t| t[:name] == "Eng #{@name}" }

    refute_nil tab
    assert_equal @name, tab[:ext_name]
  end

  private

  def json_body = ::JSON.parse(last_response.body, symbolize_names: true)

  def assert_ok
    assert_equal 200, last_response.status, "non-200 response: body=#{last_response.body[0, 500]}"
  end
end
