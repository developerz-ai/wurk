# frozen_string_literal: true

require_relative '../engine_test_helper'
require 'zlib'

# Verifies that Wurk::Engine::AssetMount is wired to serve precompiled SPA
# assets from vendor/assets/dashboard. Tests hashed filename serving and
# manifest validation.
class StaticAssetsTest < Wurk::Test::EngineCase
  parallelize_me!

  ASSETS_DIR = ::Wurk::Engine.root.join('vendor', 'assets', 'dashboard')
  MANIFEST = ASSETS_DIR.join('wurk-manifest.json')

  # The dashboard bundle under vendor/assets/dashboard is a gitignored build
  # artifact (built by `rake frontend:build`, baked into the gem at release).
  # CI rebuilds it before the suite so every assertion here must hold; a local
  # clean checkout may not have built it yet, so those runs skip rather than
  # fail a contributor's `rake test` (#257). ENV['CI'] is set by GitHub Actions.
  def test_dashboard_manifest_is_generated_by_vite_build
    skip 'manifest not built locally; run `rake frontend:build`' unless ENV['CI'] || MANIFEST.exist?

    assert_predicate MANIFEST, :exist?, "Manifest should be generated at #{MANIFEST}"
  end

  def test_dashboard_manifest_contains_version
    skip 'Manifest file missing' unless MANIFEST.exist?

    data = JSON.parse(MANIFEST.read)
    # The version is stamped at build time, so a local manifest can lag a
    # version bump until `rake frontend:build` reruns. Don't fail a clean local
    # `rake test` on that staleness (#257); CI (fresh build) still enforces it.
    skip "stale local manifest (#{data['version']} ≠ #{::Wurk::VERSION}); run `rake frontend:build`" \
      unless ENV['CI'] || data['version'] == ::Wurk::VERSION

    assert_equal ::Wurk::VERSION, data['version']
  end

  def test_dashboard_manifest_contains_timestamp
    skip 'Manifest file missing' unless MANIFEST.exist?

    data = JSON.parse(MANIFEST.read)

    assert data.key?('timestamp'), 'Manifest should have a timestamp'
    # Verify it's ISO8601 formatted
    assert_match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, data['timestamp'])
  end

  def test_asset_mount_middleware_is_configured
    middleware = Rails.application.middleware

    mount_index = middleware.each_with_index.find { |m, _i| m.klass == ::Wurk::Engine::AssetMount }&.last
    static_index = middleware.each_with_index.find { |m, _i| m.klass == ::ActionDispatch::Static }&.last

    assert mount_index, 'Wurk::Engine::AssetMount middleware should be configured'
    assert static_index, '::ActionDispatch::Static middleware should be configured'
    assert_operator mount_index, :<, static_index,
                    'Wurk::Engine::AssetMount should be inserted before ActionDispatch::Static'
  end

  # Regression for #37: Rack::Static didn't strip the URL prefix before
  # file lookup, so /wurk-assets/assets/foo.js 404'd because it resolved
  # under vendor/assets/dashboard/wurk-assets/assets/foo.js. AssetMount
  # rewrites PATH_INFO before delegating to Rack::Files.
  def test_hashed_asset_under_wurk_assets_returns_200
    asset = Dir.glob(ASSETS_DIR.join('assets', '*.js')).first
    skip 'no built JS asset to probe' unless asset

    name = File.basename(asset)
    get "/wurk-assets/assets/#{name}"

    assert_equal 200, last_response.status,
                 "expected 200 for /wurk-assets/assets/#{name}, body: #{last_response.body[0, 200]}"
    assert_equal File.binread(asset), last_response.body
  end

  def test_index_html_under_wurk_assets_returns_200
    skip 'index.html missing' unless ASSETS_DIR.join('index.html').exist?

    get '/wurk-assets/index.html'

    assert_equal 200, last_response.status
  end

  # AssetMount sits at index 0 of the HOST middleware stack, so Rack::ETag and
  # Rack::ConditionalGet never see these responses. Without an explicit
  # directive the fingerprinted bundle shipped with no Cache-Control at all and
  # browsers refetched or revalidated it on every dashboard load.
  def test_fingerprinted_asset_is_cached_immutably
    asset = Dir.glob(ASSETS_DIR.join('assets', '*.js')).first
    skip 'no built JS asset to probe' unless asset

    get "/wurk-assets/assets/#{File.basename(asset)}"

    assert_equal 200, last_response.status
    assert_equal 'public, max-age=31536000, immutable', last_response.headers['cache-control']
  end

  # index.html keeps the same name across builds, so caching it immutably would
  # pin a client to a stale dashboard shell forever. It must revalidate.
  def test_non_fingerprinted_asset_must_revalidate
    skip 'index.html missing' unless ASSETS_DIR.join('index.html').exist?

    get '/wurk-assets/index.html'

    assert_equal 200, last_response.status
    assert_equal 'public, no-cache', last_response.headers['cache-control']
    refute_includes last_response.headers['cache-control'].to_s, 'immutable'
  end

  # Rack::Files answers more than file reads: OPTIONS (200 + Allow) and 405 for
  # any other verb. 405 is cacheable by default (RFC 9110 §15.5.6), so caching
  # one immutably would let a shared proxy serve "method not allowed" for a year
  # to every client behind it.
  def test_rejected_verb_gets_no_cache_control
    asset = Dir.glob(ASSETS_DIR.join('assets', '*.js')).first
    skip 'no built JS asset to probe' unless asset

    post "/wurk-assets/assets/#{File.basename(asset)}"

    assert_equal 405, last_response.status
    assert_nil last_response.headers['cache-control']
  end

  def test_options_request_is_not_cached_immutably
    asset = Dir.glob(ASSETS_DIR.join('assets', '*.js')).first
    skip 'no built JS asset to probe' unless asset

    options "/wurk-assets/assets/#{File.basename(asset)}"

    # Rack::Files answers OPTIONS with 200 + Allow (rack/files.rb:69). The
    # contract is no cache directive at all, not merely "not immutable" —
    # asserting nil would fail if OPTIONS ever picked up `public, no-cache`.
    assert_equal 200, last_response.status
    assert_nil last_response.headers['cache-control']
  end

  def test_unknown_asset_falls_through_with_404
    get '/wurk-assets/assets/does-not-exist-xyz.js'

    assert_equal 404, last_response.status
  end

  def test_non_mount_path_is_untouched_by_asset_mount
    # Hitting a host-app path outside /wurk-assets must not be intercepted.
    get '/__definitely_not_a_real_route__'

    refute_equal 200, last_response.status
  end

  def test_vite_manifest_exists_for_asset_resolution
    # The .vite/manifest.json is used by the frontend to resolve
    # hashed filenames for linking in the SPA.
    vite_manifest = ASSETS_DIR.join('.vite', 'manifest.json')
    skip 'vite manifest not built locally; run `rake frontend:build`' unless ENV['CI'] || vite_manifest.exist?

    assert_predicate vite_manifest, :exist?, '.vite/manifest.json should be generated by Vite'

    data = JSON.parse(vite_manifest.read)

    assert_kind_of Hash, data, 'Vite manifest should be a JSON object'
    assert data.key?('index.html'), 'Vite manifest should contain index.html entry'
  end

  def test_index_html_contains_hashed_filenames
    index = ASSETS_DIR.join('index.html')
    skip 'index.html file missing' unless index.exist?

    content = index.read
    # Verify hashed filenames are present (Vite hash format: -XXXX.js/.css)
    # Vite hashes are base64url, so `-` can appear inside (or end) the hash.
    assert_match(/-[A-Za-z0-9_-]+\.js/, content, 'Should contain hashed JS filenames')
    assert_match(/-[A-Za-z0-9_-]+\.css/, content, 'Should contain hashed CSS filenames')
  end

  def test_asset_files_exist_in_directory
    assets_subdir = ASSETS_DIR.join('assets')
    skip 'assets subdirectory missing' unless assets_subdir.exist?

    files = Dir.glob("#{assets_subdir}/*.{js,css}")

    assert_predicate files, :any?, 'assets/ should contain built JS and CSS files'
  end

  # `rake frontend:build` writes .br and .gz siblings for every fingerprinted
  # JS/CSS file; the mount answers Accept-Encoding with them because it sits
  # ahead of any deflater the host runs.
  def compressed_asset
    asset = Dir.glob(ASSETS_DIR.join('assets', '*.js')).find { |f| File.exist?("#{f}.br") && File.exist?("#{f}.gz") }
    skip 'no precompressed JS asset; run `rake frontend:build`' unless asset
    asset
  end

  def test_brotli_variant_when_the_client_accepts_br
    asset = compressed_asset

    get "/wurk-assets/assets/#{File.basename(asset)}", {}, 'HTTP_ACCEPT_ENCODING' => 'gzip, deflate, br'

    assert_equal 200, last_response.status
    assert_equal 'br', last_response.headers['content-encoding']
    assert_equal 'accept-encoding', last_response.headers['vary']
    assert_match %r{\Atext/javascript}, last_response.headers['content-type']
    assert_equal File.binread("#{asset}.br"), last_response.body
    assert_equal 'public, max-age=31536000, immutable', last_response.headers['cache-control']
  end

  def test_gzip_variant_when_the_client_accepts_only_gzip
    asset = compressed_asset

    get "/wurk-assets/assets/#{File.basename(asset)}", {}, 'HTTP_ACCEPT_ENCODING' => 'gzip'

    assert_equal 200, last_response.status
    assert_equal 'gzip', last_response.headers['content-encoding']
    assert_equal 'accept-encoding', last_response.headers['vary']
    assert_match %r{\Atext/javascript}, last_response.headers['content-type']
    assert_equal File.binread(asset), Zlib.gunzip(last_response.body)
  end

  def test_a_lower_q_value_loses_even_when_listed_first
    asset = compressed_asset

    get "/wurk-assets/assets/#{File.basename(asset)}", {}, 'HTTP_ACCEPT_ENCODING' => 'br;q=0.1, gzip;q=0.9'

    assert_equal 'gzip', last_response.headers['content-encoding']
  end

  def test_identity_when_the_client_accepts_no_encoding_or_refuses_them
    asset = compressed_asset

    [nil, 'identity', 'br;q=0, gzip;q=0'].each do |accept|
      headers = accept ? { 'HTTP_ACCEPT_ENCODING' => accept } : {}
      get "/wurk-assets/assets/#{File.basename(asset)}", {}, headers

      assert_equal 200, last_response.status, accept.inspect
      assert_nil last_response.headers['content-encoding'], accept.inspect
      assert_equal 'accept-encoding', last_response.headers['vary'], accept.inspect
      assert_equal File.binread(asset), last_response.body, accept.inspect
    end
  end

  # Byte offsets in a Range header address the identity file.
  def test_range_request_is_served_from_the_identity_file
    asset = compressed_asset

    get "/wurk-assets/assets/#{File.basename(asset)}", {}, 'HTTP_ACCEPT_ENCODING' => 'br', 'HTTP_RANGE' => 'bytes=0-9'

    assert_equal 206, last_response.status
    assert_nil last_response.headers['content-encoding']
    assert_equal File.binread(asset, 10), last_response.body
  end

  def test_asset_without_a_variant_is_served_as_is
    font = Dir.glob(ASSETS_DIR.join('assets', '*.woff2')).first
    skip 'no built font to probe' unless font

    get "/wurk-assets/assets/#{File.basename(font)}", {}, 'HTTP_ACCEPT_ENCODING' => 'br, gzip'

    assert_equal 200, last_response.status
    assert_nil last_response.headers['content-encoding']
    assert_nil last_response.headers['vary']
  end
end
