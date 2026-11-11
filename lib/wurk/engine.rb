# frozen_string_literal: true

require 'rails/engine'
require_relative '../active_job/queue_adapters/wurk_adapter'
require_relative 'dashboard_manifest'

module Wurk
  # Rails mountable engine. Owns the dashboard mount, the asset path for
  # the precompiled SPA, and (via the sibling railtie) the after_initialize
  # hook that boots the swarm.
  class Engine < ::Rails::Engine
    isolate_namespace Wurk

    config.generators do |g|
      g.test_framework :minitest, fixtures: false
    end

    # Rack::Files doesn't strip the URL prefix before file lookup, so
    # `/wurk-assets/assets/foo.js` would resolve under `vendor/assets/dashboard/
    # wurk-assets/assets/foo.js` — a path that doesn't exist. AssetMount
    # rewrites PATH_INFO to drop the `/wurk-assets` prefix before delegating
    # to Rack::Files, then falls through to the next middleware on 404 so
    # host-app routes outside the mount keep working.
    class AssetMount
      PREFIX = '/wurk-assets'

      # Vite fingerprints everything it emits into `assets/`
      # (`Dashboard-cGKycyd0.js`), so the bytes behind one of those URLs can
      # never change — cache them for a year and never revalidate. The rest of
      # the bundle (index.html, the favicons, wurk-manifest.json,
      # .vite/manifest.json) keeps a stable name across builds, so it must be
      # revalidated or a client would pin a stale dashboard shell forever.
      FINGERPRINTED_PREFIX = '/assets/'
      IMMUTABLE_CACHE_CONTROL = 'public, max-age=31536000, immutable'
      REVALIDATE_CACHE_CONTROL = 'public, no-cache'

      # Only a served body gets a cache directive. Rack::Files answers more than
      # file reads: OPTIONS with 200 + Allow, 405 for any other verb
      # (`ALLOWED_VERBS = %w[GET HEAD OPTIONS]`), and 416 for an unsatisfiable
      # Range. 405 is cacheable by default (RFC 9110 §15.5.6), so stamping it
      # `immutable` would let a shared proxy serve "method not allowed" for a
      # year to everyone behind it.
      CACHEABLE_METHODS = %w[GET HEAD].freeze
      CACHEABLE_STATUSES = [200, 206, 304].freeze

      # `rake frontend:build` writes a .br and a .gz next to each fingerprinted
      # text asset (frontend/vite.config.ts, wurk-precompress). The mount sits
      # ahead of any deflater the host runs, so without these the dashboard
      # went out uncompressed. Preference order when the client's q-values tie.
      ENCODINGS = { 'br' => '.br', 'gzip' => '.gz' }.freeze
      OFFERED_ENCODINGS = [*ENCODINGS.keys, 'identity'].freeze
      PRECOMPRESSED = /\.(?:js|css|svg|json)\z/

      def initialize(app, root:)
        @app   = app
        @files = ::Rack::Files.new(root)
      end

      def call(env)
        path = env[::Rack::PATH_INFO]
        return @app.call(env) unless path == PREFIX || path.start_with?("#{PREFIX}/")

        inner = env.dup
        stripped = path.delete_prefix(PREFIX)
        inner[::Rack::PATH_INFO] = stripped.empty? ? '/' : stripped
        response = precompressed(inner, env, stripped) || @files.call(inner)
        return @app.call(env) if response[0] == 404

        stamp_cache_headers(response, env, stripped)
        response
      end

      private

      # The variant the client accepts and the build wrote, served with the
      # original's content type; nil sends the identity file. A Range request
      # gets identity so byte offsets mean what the client thinks they mean.
      def precompressed(inner, env, stripped)
        return unless CACHEABLE_METHODS.include?(env[::Rack::REQUEST_METHOD])
        return unless precompressible?(stripped)
        return if env['HTTP_RANGE']

        encoding = negotiated_encoding(env)
        return unless encoding

        variant = @files.call(inner.merge(::Rack::PATH_INFO => "#{stripped}#{ENCODINGS[encoding]}"))
        return unless variant[0] == 200

        variant[1]['content-type'] = ::Rack::Mime.mime_type(::File.extname(stripped))
        variant[1]['content-encoding'] = encoding
        variant
      end

      # 'br', 'gzip', or nil for identity (no header, or every coding refused).
      def negotiated_encoding(env)
        accepted = ::Rack::Utils.q_values(env['HTTP_ACCEPT_ENCODING'].to_s)
        encoding = ::Rack::Utils.select_best_encoding(OFFERED_ENCODINGS, accepted)
        encoding if ENCODINGS.key?(encoding)
      end

      def precompressible?(stripped)
        stripped.start_with?(FINGERPRINTED_PREFIX) && stripped.match?(PRECOMPRESSED)
      end

      # This mount is inserted at index 0 of the HOST app's stack (see the
      # initializer below), so Rack::ETag and Rack::ConditionalGet never see
      # these responses — without this the dashboard's fingerprinted bundle
      # shipped with no cache directive at all and was refetched every load.
      #
      # Vary goes on every answer for a path that has variants, identity
      # included, or a shared cache could hand gzip to a client that can't
      # read it.
      def stamp_cache_headers(response, env, stripped)
        response[1]['vary'] = 'accept-encoding' if precompressible?(stripped)
        return unless CACHEABLE_METHODS.include?(env[::Rack::REQUEST_METHOD])
        return unless CACHEABLE_STATUSES.include?(response[0])

        response[1]['cache-control'] ||=
          if stripped.start_with?(FINGERPRINTED_PREFIX)
            IMMUTABLE_CACHE_CONTROL
          else
            REVALIDATE_CACHE_CONTROL
          end
      end
    end

    # Precompiled SPA lives in vendor/assets/dashboard; the engine serves
    # those files as static assets under the /wurk-assets mount point via
    # AssetMount (above).
    #
    # Deliberately unauthenticated: this middleware is inserted straight into
    # the *host app's* middleware stack (`app.middleware`), not the engine's
    # own (`middleware.use` in this class, below) — so it runs before
    # anything wired via `Wurk::Web.use`/`Authorization` even sees the
    # request, and `/wurk-assets/*` is reachable without passing either
    # check. That's intentional, not an oversight: the bundle is the
    # compiled JS/CSS/font shell only (no job payloads, no Redis reads, no
    # per-user state — every data-bearing byte comes from the JSON API,
    # which *does* sit behind the engine's Authorization middleware). It's
    # the same trust model as serving `public/assets` from any other Rails
    # app. See README "Security notes" for the full reasoning.
    initializer 'wurk.assets' do |app|
      assets_path = Wurk::Engine.root.join('vendor', 'assets', 'dashboard')
      if assets_path.exist?
        # Index 0, not insert_before(ActionDispatch::Static): Static is only
        # in the stack when public_file_server is enabled, and a stock
        # production deploy behind nginx (RAILS_SERVE_STATIC_FILES unset)
        # omits it — insert_before(Static) would crash the host app's boot.
        app.middleware.insert_before(
          0,
          ::Wurk::Engine::AssetMount,
          root: assets_path.to_s
        )
      end
    end

    # Fail boot in production if the precompiled bundle is missing or its
    # version doesn't match the gem. Dev and test skip — contributors don't
    # always have a fresh build, and Vite dev mode owns the shell directly.
    initializer 'wurk.dashboard_manifest_check' do
      next if ENV['WURK_VITE_DEV'] == '1'
      next unless ::Rails.env.production?

      ::Wurk::DashboardManifest.check!
    end

    # Engine-scoped Rack middleware. Inserted into the engine — not the host —
    # so the host's own controllers stay unaffected; only requests routed
    # under the mount point pass through.
    #
    #   * MiddlewareStack — host-app auth via `Wurk::Web.use` (#41). Outermost,
    #     so Devise/Warden/Sorcery run first and their `env` is visible to the
    #     authorization hook below.
    #   * Authorization — the `Wurk::Web.configure` authorization + read-only
    #     hook (sidekiq-ent §9.2), 403 on falsey.
    middleware.use ::Wurk::Web::MiddlewareStack
    middleware.use ::Wurk::Web::Authorization
  end
end
