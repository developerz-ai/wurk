# frozen_string_literal: true

require 'json'
require 'rack'

module Wurk
  class Web
    module Dashboard
      # The slice of the ActionController interface the dashboard's shared
      # actions use (Dashboard::ApiActions, ProfileActions, ExtensionActions),
      # over plain Rack, so `run Sidekiq::Web` serves the same dashboard as the
      # engine without Rails (CLAUDE.md: standalone mode never loads the
      # engine). The engine's controllers include the same action modules and
      # get these methods from ActionController instead.
      class Controller
        # `params[:name]` and `params['name']` alike, as ActionController's.
        class Params < ::Hash
          def [](key) = super(key.to_s)
          def key?(key) = super(key.to_s)
          def fetch(key, *, &) = super(key.to_s, *, &)
        end

        # The request readers the actions call, under ActionDispatch's names.
        class Request < ::Rack::Request
          def headers = Headers.new(env)
          def get_header(name) = env[name]
          def content_security_policy_nonce = nil
        end

        # `request.headers['Sec-Fetch-Site']` reads `HTTP_SEC_FETCH_SITE`.
        Headers = Struct.new(:env) do
          def [](name) = env["HTTP_#{name.upcase.tr('-', '_')}"]
        end

        Response = Struct.new(:headers)

        JSON_TYPE = 'application/json; charset=utf-8'

        class << self
          def before_action(name)
            before_actions << name
          end

          def before_actions
            @before_actions ||= superclass.respond_to?(:before_actions) ? superclass.before_actions.dup : []
          end

          # A Rack triple for `action`, with `path_params` from the route.
          def call(env, action, path_params = {})
            new(env, path_params).dispatch(action)
          end
        end

        attr_reader :request, :response

        def initialize(env, path_params)
          @request = Request.new(env)
          @response = Response.new({})
          @path_params = path_params
          @result = nil
        end

        def params
          @params ||= Params.new.merge!(request_params.transform_keys(&:to_s))
                            .merge!(@path_params.transform_keys(&:to_s))
        end

        def dispatch(action)
          self.class.before_actions.each do |name|
            send(name)
            return @result if @result
          end
          public_send(action)
          @result || head(:no_content)
        rescue *::Wurk::Configuration::REDIS_ERROR_CLASSES => e
          ::Wurk.logger.warn("wurk web: redis unavailable (#{e.class}: #{e.message})")
          @result = nil
          render json: { error: 'redis_unavailable' }, status: :service_unavailable
        end

        def logger = ::Wurk.logger

        private

        def render(json: nil, html: nil, body: nil, status: 200, content_type: nil, layout: nil) # rubocop:disable Lint/UnusedMethodArgument -- ActionController's keyword
          if json
            finish(status, content_type || JSON_TYPE, Dashboard.json(json))
          else
            finish(status, content_type || 'text/html; charset=utf-8', (html || body).to_s)
          end
        end

        def head(status)
          finish(status, nil, '')
        end

        def redirect_to(url, allow_other_host: false) # rubocop:disable Lint/UnusedMethodArgument -- ActionController's keyword
          response.headers['location'] = url.to_s
          finish(302, nil, '')
        end

        def send_data(data, type:, disposition: 'inline')
          response.headers['content-disposition'] = disposition
          finish(200, type, data.to_s)
        end

        def send_file(path, disposition: 'inline')
          send_data(::File.binread(path), type: ::Rack::Mime.mime_type(::File.extname(path.to_s)),
                                          disposition: disposition)
        end

        def finish(status, content_type, body)
          headers = response.headers.transform_keys(&:downcase)
          headers['content-type'] = content_type if content_type
          @result = [::Rack::Utils.status_code(status), headers, [body]]
        end

        # Rack parses the query string and a form body; the SPA posts JSON.
        def request_params
          form = request.params
          return form unless request.media_type == 'application/json'

          parsed = ::JSON.parse(request.body&.read.to_s.then { |raw| raw.empty? ? '{}' : raw })
          parsed.is_a?(::Hash) ? form.merge(parsed) : form
        rescue ::JSON::ParserError
          form
        end
      end

      # JSON as ActiveSupport's encoder writes it for the payloads the
      # dashboard renders: a non-finite float is null rather than an
      # unparseable `NaN`, and a Time is ISO 8601.
      def self.json(value) = ::JSON.generate(encodable(value))

      def self.encodable(value)
        case value
        when ::Hash then value.to_h { |k, v| [k.to_s, encodable(v)] }
        when ::Array then value.map { |v| encodable(v) }
        when ::Float then value.finite? ? value : nil
        when ::Time then value.iso8601(3)
        else value
        end
      end
    end
  end
end
