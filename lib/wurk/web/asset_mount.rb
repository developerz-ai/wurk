# frozen_string_literal: true

require 'rack'

module Wurk
  class Web
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

      # The precompiled bundle `rake frontend:build` writes and the gem ships.
      DEFAULT_ROOT = ::File.expand_path('../../../vendor/assets/dashboard', __dir__)

      def initialize(app, root: DEFAULT_ROOT)
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

      # The engine inserts this mount at index 0 of the HOST app's stack
      # (its `wurk.assets` initializer), so Rack::ETag and Rack::ConditionalGet never see
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
  end
end
