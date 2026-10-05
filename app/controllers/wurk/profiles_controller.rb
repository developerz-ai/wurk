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
      # GET-shaped for Sidekiq parity, but uploading the profile to the public
      # Firefox profiler store is a side effect — read-only deploys (e.g. the
      # public demo) must not let any visitor exfiltrate profiling data.
      return head(:forbidden) if ::Wurk::Web.config.read_only?

      sid = profile_sid(params[:key])
      return head(:not_found) if sid == :missing
      return head(:bad_gateway) unless sid

      redirect_to(format(::Wurk::Web.config.profile_view_url, sid), allow_other_host: true)
    end

    private

    def profile_blob(key)
      ::Wurk::ProfileRecord.data_for(key)
    end

    # The profile-store id, cached in the HASH's `sid` field after the first
    # upload exactly as Sidekiq's Web UI does, so either UI reuses the other's
    # upload. :missing when the profile is gone, nil when the upload failed.
    def profile_sid(key)
      sid = ::Wurk.redis { |c| c.call('HGET', key, 'sid') }
      return sid if sid

      blob = profile_blob(key)
      return :missing unless blob

      sid = upload_to_profiler(blob)
      ::Wurk.redis { |c| c.call('HSET', key, 'sid', sid) } if sid
      sid
    end

    # POSTs the gzipped profile to the Firefox profiler's compressed-store,
    # which answers with a JWT whose payload carries the `profileToken` the
    # view URL needs. Returns that token, or nil on failure.
    def upload_to_profiler(gzipped)
      uri = URI.parse(::Wurk::Web.config.profile_store_url)
      res = post_gzip(uri, gzipped)
      res.is_a?(Net::HTTPSuccess) ? profile_token(res.body.to_s) : nil
    rescue StandardError => e
      Wurk.configuration.handle_exception(e, context: 'Wurk::ProfilesController#upload')
      nil
    end

    def profile_token(jwt)
      payload = jwt.strip.split('.')[1].to_s.tr('-_', '+/')
      ::JSON.parse(payload.unpack1('m'))['profileToken']
    end

    def post_gzip(uri, body)
      req = Net::HTTP::Post.new(uri)
      req['Content-Encoding'] = 'gzip'
      req['Content-Type'] = 'application/json'
      req['Accept'] = 'application/vnd.firefox-profiler+json;version=1.0'
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
