# frozen_string_literal: true

require 'erb'
require 'cgi'
require 'securerandom'

module Wurk
  class Web
    # Server-side renderer for third-party Web extensions (spec §25, #187).
    #
    # Sidekiq extensions register Sinatra-style routes + ERB views via
    # `Sidekiq::Web.register(Ext, name:, tab:, index:, root_dir:, asset_paths:)`,
    # where `Ext.registered(app)` calls `app.get "/path" do … end` and
    # `app.helpers SomeModule`. wurk's dashboard is a React SPA with no Sinatra
    # render path, so this module provides a minimal, Sidekiq-Web-compatible
    # renderer: it captures the routes, runs the matched block in an `Action`
    # context (a `WebHelpers` subset + the ext's own helpers + `erb`), and
    # returns the rendered HTML for the SPA's Extension page to embed.
    #
    # It does NOT depend on the `sidekiq` gem — extensions registered through
    # wurk's own `Sidekiq::Web.register` alias render unchanged. (Running a
    # real third-party gem unmodified additionally needs the shim in #204.)
    module Extension
      # Captures the routes + helpers an extension declares in `registered`.
      # Quacks like the slice of `Sidekiq::Web::Application` extensions touch.
      class App
        attr_reader :routes, :helper_modules, :helper_blocks

        HTTP_METHODS = %i[get post put patch delete head].freeze

        def initialize
          @routes = [] # [[method_string, Route, block], …]
          @helper_modules = []
          @helper_blocks = []
        end

        HTTP_METHODS.each do |verb|
          define_method(verb) do |path, &block|
            @routes << [verb.to_s.upcase, Route.new(path), block]
          end
        end

        # Sidekiq extensions add helpers via `app.helpers(Mod)` and/or a block.
        def helpers(*mods, &block)
          @helper_modules.concat(mods)
          @helper_blocks << block if block
          self
        end

        # Sinatra settings calls some extensions make — accepted no-op.
        def set(*); end
        def settings = self
        def configure(*) = (yield self if block_given?)
      end

      # Compiles a Sinatra-style path ("/locks/:digest") into a matcher that
      # extracts Symbol-keyed route params. A trailing "*" matches the rest.
      class Route
        NAMED = %r{/([^/]*):([^./:$]+)}

        attr_reader :path

        def initialize(path)
          @path = path.to_s
          @keys = []
          @regex = compile(@path)
        end

        # Returns a `{key => value}` Hash of route params, or nil if no match.
        def match(path)
          m = @regex.match(path)
          return nil unless m

          @keys.each_with_index.to_h { |k, i| [k, m[i + 1] && CGI.unescape(m[i + 1])] }
        end

        private

        def compile(path)
          return /\A#{::Regexp.escape(path[0..-2])}.*\z/ if path.end_with?('*')

          %r{\A#{escaped_pattern(path)}/?\z}
        end

        # Escape every literal fragment so route text like ".json" or "+"
        # matches itself instead of acting as a regex metacharacter.
        def escaped_pattern(path)
          pattern = +''
          pos = 0
          path.scan(NAMED) { pos = append_param(pattern, path, pos, ::Regexp.last_match) }
          pattern << ::Regexp.escape(path[pos..])
        end

        def append_param(pattern, path, pos, match)
          @keys << match[2].to_sym
          pattern << ::Regexp.escape(path[pos...match.begin(0)]) << "/#{::Regexp.escape(match[1])}([^/?#]+)"
          match.end(0)
        end
      end

      # The `WebHelpers` subset real extension views/routes call. Mixed into
      # every `Action`. Anything an exotic gem needs beyond this can be added
      # incrementally; the common surface (escaping, paths, time, i18n) is here.
      module Helpers
        def h(text) = ::CGI.escapeHTML(text.to_s)

        # Truncate long text (display safety) — mirrors Sidekiq's default cap.
        def truncate(text, max = 2000)
          str = text.to_s
          str.size > max ? "#{str[0, max]}…" : str
        end

        # Best-effort arg display, matching Sidekiq's `to_display`.
        def to_display(arg)
          str = arg.inspect
          str.size > 100 ? "#{str[0, 100]}…" : str
        end

        # i18n: look up the extension's own locale strings if present, else the
        # humanized key (so a missing translation degrades, never raises).
        def t(key, options = {})
          val = (@ext_strings || {}).dig(*key.to_s.split('.'))
          str = val.is_a?(::String) ? val : key.to_s.tr('_', ' ').capitalize
          options.each { |k, v| str = str.gsub("%{#{k}}", v.to_s) }
          str
        end

        # Engine-absolute base path for this extension, trailing slash, so an
        # ext's `root_path + "locks"` links land back on our embed endpoint.
        def root_path = "#{@mount}/ext/#{@ext_name}/"
        def current_path = @subpath.to_s.sub(%r{\A/}, '')
        def asset_path(file) = "#{@mount}/ext-assets/#{@ext_name}/#{file}"

        # GET-form embeds don't need CSRF; return an empty, benign tag.
        def csrf_tag = ''
        def csp_nonce = (@csp_nonce ||= ::SecureRandom.hex(8))

        # `<time>` element like Sidekiq's relative_time; JS upgrades it client-side.
        def relative_time(time)
          t = time.is_a?(::Time) ? time : ::Time.at(time.to_f)
          iso = t.utc.iso8601
          %(<time class="ltr" dir="ltr" title="#{iso}" datetime="#{iso}">#{iso}</time>)
        end

        def redis(&) = ::Wurk.redis(&)
        def product_version = ::Wurk::VERSION
        def number_with_delimiter(num) = num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      end

      # Per-request render context: instance-evals a matched route block, then
      # renders ERB with the block's ivars + helpers in scope.
      class Action
        include Helpers

        # Internal-redirect signal carried out of a route block via throw/catch.
        Redirect = ::Struct.new(:location)

        def initialize(env:, route_params:, ext:, mount:)
          @env = env
          @request = ::Rack::Request.new(env)
          @route_params = route_params
          @ext_name = ext[:name].to_s
          @root_dir = ext[:root_dir]
          @ext_strings = ext[:strings]
          @mount = mount.to_s
          @subpath = env['wurk.ext.subpath']
          extend_helpers(ext[:helpers])
        end

        attr_reader :env, :request

        def params = @params ||= symbolize(@request.params).merge(@route_params)
        def url_params(key) = @request.params[key.to_s]
        def route_params(key = nil) = key ? @route_params[key.to_sym] : @route_params
        def session = (@env['rack.session'] ||= {})
        def logger = ::Wurk.logger
        def redirect(location) = throw(:wurk_ext_halt, Redirect.new(location))

        # Render an ERB template. `content` is either the template String (the
        # common path — the ext's own helper reads the file) or a Symbol naming
        # a `*.erb` under the ext's root_dir/views.
        def erb(content, _options = {})
          template = content.is_a?(::Symbol) ? read_view(content) : content.to_s
          ::ERB.new(template, trim_mode: '-').result(binding)
        end

        # Run the route block in this context, capturing redirects. Returns the
        # rendered HTML String, or a Redirect.
        def run(block)
          catch(:wurk_ext_halt) { instance_exec(&block) }
        end

        private

        def read_view(name)
          raise ::ArgumentError, "extension #{@ext_name} has no root_dir" unless @root_dir

          ::File.read(::File.join(@root_dir, 'views', "#{name}.erb"))
        end

        def extend_helpers(helpers)
          Array(helpers && helpers[:modules]).each { |mod| extend(mod) }
          Array(helpers && helpers[:blocks]).each { |blk| instance_eval(&blk) if blk }
        end

        def symbolize(hash) = hash.to_h.transform_keys(&:to_sym)
      end

      # Ties it together: finds a registered extension by name, captures its
      # routes once (`registered(app)`), matches the request, and renders.
      class Renderer
        class << self
          # @return [Array(Integer, Hash, String)] Rack-ish [status, headers,
          #   body] — 200 HTML, 302 redirect, or 404 — or nil when no extension
          #   with `name` is registered (so the engine can fall through).
          def call(name:, method:, subpath:, env:, mount:)
            ext = registered_extension(name)
            return nil unless ext

            verb = method.to_s.upcase
            route, block, route_params = match_route(ext, verb, subpath)
            return [404, html_headers, "No #{verb} route #{subpath} in extension #{name}"] unless route

            env['wurk.ext.subpath'] = subpath
            render(ext, route_params, block, env, mount)
          end

          # `[absolute_path, cache_for_seconds]` of an asset under the
          # extension's asset_paths, or nil if the extension/file isn't found.
          # The expand_path prefix check rejects `../` traversal out of the dir.
          def asset_file(name, file)
            ext = registered_extension(name)
            return nil unless ext

            Array(ext[:asset_paths]).each do |dir|
              path = ::File.expand_path(::File.join(dir, file.to_s))
              next unless path.start_with?("#{::File.expand_path(dir)}/") && ::File.file?(path)

              return [path, ext[:cache_for] || 86_400]
            end
            nil
          end

          private

          def registered_extension(name)
            ::Wurk::Web.config.extensions.find { |e| e[:name].to_s == name.to_s }
          end

          def render(ext, route_params, block, env, mount)
            result = action_for(ext, route_params, env, mount).run(block)
            if result.is_a?(Action::Redirect)
              [302, { 'Location' => redirect_target(result.location, ext, mount) }, '']
            else
              [200, html_headers, result.to_s]
            end
          rescue ::StandardError => e
            ::Wurk.configuration.handle_exception(e, context: 'web-extension-render')
            [500, html_headers, "Extension render error: #{::CGI.escapeHTML(e.message)}"]
          end

          def action_for(ext, route_params, env, mount)
            app = captured_app(ext)
            Action.new(
              env: env, route_params: route_params, mount: mount,
              ext: ext.merge(helpers: { modules: app.helper_modules, blocks: app.helper_blocks },
                             strings: strings_for(ext))
            )
          end

          def match_route(ext, verb, subpath)
            captured_app(ext).routes.each do |meth, route, block|
              next unless meth == verb

              params = route.match(subpath)
              return [route, block, params] if params
            end
            [nil, nil, nil]
          end

          # Capture the ext's routes/helpers once; memoize on the config entry.
          def captured_app(ext)
            ext[:_app] ||= App.new.tap do |app|
              ext[:extension].registered(app) if ext[:extension].respond_to?(:registered)
            end
          end

          # An ext's redirect target is relative to its mount ("locks" → the
          # embed endpoint). Absolute URLs pass through unchanged.
          def redirect_target(location, ext, mount)
            loc = location.to_s
            return loc if loc.match?(%r{\A[a-z]+://}i)

            "#{mount}/ext/#{ext[:name]}/#{loc.sub(%r{\A/}, '')}"
          end

          def strings_for(ext)
            ext.fetch(:_strings) do
              dir = ext[:root_dir]
              file = dir && ::File.join(dir, 'locales', 'en.yml')
              ext[:_strings] = (file && ::File.exist?(file) ? load_yaml(file) : {})
            end
          end

          def load_yaml(file)
            require 'yaml'
            data = ::YAML.safe_load_file(file)
            data.is_a?(::Hash) ? (data.values.first || data) : {}
          rescue ::StandardError
            {}
          end

          def html_headers = { 'Content-Type' => 'text/html; charset=utf-8' }
        end
      end
    end
  end
end
