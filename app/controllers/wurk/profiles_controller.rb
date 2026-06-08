# frozen_string_literal: true

require 'net/http'
require 'uri'

module Wurk
  # Profiles pane non-JSON endpoints (spec §25.4):
  #
  #   GET /profiles/:key/data  → the stored gzipped gecko JSON, streamed with a
  #                              gzip Content-Encoding (Firefox profiler pulls
  #                              this when given a `from-url` source).
  #   GET /profiles/:key       → upload the profile to the Firefox profiler
  #                              store and 302 to its public view URL.
  #
  # `:key` is "<token>-<jid>". The JSON list lives at /api/profiles.
  class ProfilesController < ApplicationController
    # CSRF protection is for state-changing form posts; these are GET reads.
    skip_forgery_protection

    def data
      blob = profile_blob(params[:key])
      return head(:not_found) unless blob

      response.headers['Content-Encoding'] = 'gzip'
      send_data blob, type: 'application/json', disposition: 'inline'
    end

    def show
      blob = profile_blob(params[:key])
      return head(:not_found) unless blob

      hash = upload_to_profiler(blob)
      return head(:bad_gateway) unless hash

      redirect_to(format(::Wurk::Web.config.profile_view_url, hash), allow_other_host: true)
    end

    private

    def profile_blob(key)
      Wurk.redis { |conn| conn.call('HGET', key, 'data') }
    end

    # POSTs the gzipped profile to the Firefox profiler's compressed-store.
    # Returns the public hash (used to build the view URL) or nil on failure.
    def upload_to_profiler(gzipped)
      uri = URI.parse(::Wurk::Web.config.profile_store_url)
      res = post_gzip(uri, gzipped)
      res.is_a?(Net::HTTPSuccess) ? res.body.to_s.strip : nil
    rescue StandardError => e
      Wurk.configuration.handle_exception(e, context: 'Wurk::ProfilesController#upload')
      nil
    end

    def post_gzip(uri, body)
      req = Net::HTTP::Post.new(uri)
      req['Content-Encoding'] = 'gzip'
      req['Content-Type'] = 'application/json'
      req.body = body
      # Explicit timeouts so a slow/unreachable profiler can't tie up the Rails
      # request thread for Ruby's ~60s defaults.
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                          open_timeout: 5, read_timeout: 15) do |http|
        http.request(req)
      end
    end
  end
end
