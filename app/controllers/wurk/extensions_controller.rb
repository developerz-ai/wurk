# frozen_string_literal: true

require 'wurk/web/extension'

module Wurk
  # Serves third-party Web extensions (#187): `ext/:name/*subpath` runs the
  # registered extension's matched route and returns its rendered HTML for the
  # SPA's Extension page to embed; `ext-assets/:name/*file` serves files from
  # the extension's `asset_paths`.
  #
  # Inherits DashboardController so an /ext/* URL that is actually the SPA's
  # client-side route (no extension registered under that name — e.g. a browser
  # refresh on /wurk/ext/<tab>/) falls through to the SPA shell instead of 404.
  class ExtensionsController < DashboardController
    # Extension forms carry no Rails CSRF token. Parity with Sidekiq's own
    # CSRF model instead (spec §25.1): unsafe methods must be same-origin per
    # Sec-Fetch-Site; cross-site requests are denied. GETs are unaffected.
    skip_forgery_protection
    before_action :verify_same_origin!, unless: -> { request.get? || request.head? }

    def show
      result = Web::Extension::Renderer.call(
        name: params[:name], method: request.request_method,
        subpath: "/#{params[:subpath]}", env: request.env, mount: request.script_name
      )
      return index unless result # not an extension → SPA client route; let the SolidJS router handle it

      respond_with(result)
    end

    def asset
      file, cache_for = Web::Extension::Renderer.asset_file(params[:name], params[:file])
      return head :not_found unless file

      response.headers['Cache-Control'] = "public, max-age=#{cache_for}"
      send_file file, disposition: 'inline'
    end

    private

    def respond_with((status, headers, body))
      return redirect_to(headers['Location'], allow_other_host: false) if status == 302

      # Extension output is host-registered server code, same trust model as
      # Sidekiq::Web rendering its extensions — not user input.
      render html: body.html_safe, layout: false, status: status
    end

    # Spec §25.1: unsafe methods require `Sec-Fetch-Site: same-origin` — a
    # missing header is denied too, like stock Sidekiq (a non-browser client
    # must spoof the header deliberately; a cookie-carrying browser can't).
    def verify_same_origin!
      head :forbidden unless request.headers['Sec-Fetch-Site'] == 'same-origin'
    end
  end
end
