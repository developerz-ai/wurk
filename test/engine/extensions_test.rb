# frozen_string_literal: true

require_relative '../engine_test_helper'

# Drives the Web-extension endpoints (#187) against the booted dummy app:
# `GET/POST /wurk/ext/:name/*` renders the registered extension's route and
# `GET /wurk/ext-assets/:name/*` serves its asset_paths. Registers a synthetic
# extension under a per-test unique name and removes it in teardown.
class ExtensionsTest < Wurk::Test::EngineCase
  parallelize_me!

  FIXTURE_DIR = File.expand_path('../fixtures/demo_ext', __dir__)

  module EngineExt
    def self.registered(app)
      app.get '/list' do
        erb '<table class="ext-table"><tr><td><%= h(url_params("q") || "all") %></td></tr></table>'
      end
      app.get '/list/clear' do
        redirect 'list'
      end
      app.post '/list' do
        erb '<p>posted</p>'
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

  def test_extension_redirect_stays_under_the_embed_base
    get "/wurk/ext/#{@name}/list/clear"

    assert_equal 302, last_response.status
    assert_includes last_response.headers['Location'], "/wurk/ext/#{@name}/list"
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
