# frozen_string_literal: true

require 'securerandom'

module Wurk
  class Web
    module Extension
      # What extension views and routes call, `Sidekiq::WebHelpers` by its upstream
      # name (spec §25.7). Mixed into every Action. A class that includes it to test
      # one helper (unique-jobs' specs do) only has to answer `params` for the ones
      # that read the request.
      module Helpers
        # Frozen would break sidekiq-status, which appends to it at load.
        SAFE_QPARAMS = %w[page direction] # rubocop:disable Style/MutableConstant

        # Job fields the job-detail partial already shows, so anything else is extra.
        RETRY_JOB_KEYS = %w[
          queue class args retry_count retried_at failed_at jid error_message error_class backtrace
          error_backtrace enqueued_at retry wrapped created_at
        ].freeze

        def h(text) = ::CGI.escapeHTML(text.to_s)

        def truncate(text, max = 2000)
          str = text.to_s
          max && str.size > max ? "#{str[0..max]}..." : str
        end

        # Best-effort arg display, matching Sidekiq's `to_display`.
        def to_display(arg)
          str = arg.inspect
          str.size > 100 ? "#{str[0, 100]}…" : str
        end

        def display_args(args, max = 2000)
          return 'Invalid job payload, args is nil' if args.nil?
          return "Invalid job payload, args must be an Array, not #{args.class}" unless args.respond_to?(:map)
          return 'Invalid job payload, args must be an Array, not Hash' if args.is_a?(::Hash)

          args.map { |arg| h(truncate(arg.inspect, max)) }.join(', ')
        end

        # The extension's own locale strings, then the English an upstream key
        # spells ("DeleteAll" reads "Delete All"), so a missing translation
        # degrades and never raises.
        def t(key, options = {})
          val = (@ext_strings || {}).dig(*key.to_s.split('.'))
          str = val.is_a?(::String) ? val : humanize_key(key.to_s)
          options.each { |k, v| str = str.gsub("%{#{k}}", v.to_s) }
          str
        end

        # Base path for this extension, trailing slash. Embedded in the
        # engine, ext links must land back on the embed endpoint
        # (`/wurk/ext/<name>/…`); standalone (`run Sidekiq::Web`, #204) the
        # ext's routes ARE the URL space, so it's the app root — upstream's
        # `"#{env['SCRIPT_NAME']}/"` semantics.
        def root_path = @embed ? "#{@mount}/ext/#{@ext_name}/" : "#{@mount}/"
        def current_path = @subpath.to_s.sub(%r{\A/}, '')

        def asset_path(file)
          @embed ? "#{@mount}/ext-assets/#{@ext_name}/#{file}" : "#{@mount}/#{@ext_name}/#{file}"
        end

        # GET-form embeds don't need CSRF; return an empty, benign tag.
        def csrf_tag = ''
        def csp_nonce = (@csp_nonce ||= ::SecureRandom.hex(8))

        # `<time>` element like Sidekiq's relative_time; JS upgrades it client-side.
        def relative_time(time)
          t = time.is_a?(::Time) ? time : ::Time.at(time.to_f)
          iso = t.utc.iso8601
          %(<time class="ltr" dir="ltr" title="#{iso}" datetime="#{iso}">#{iso}</time>)
        end

        def redis(idempotent: false, &) = ::Wurk.redis(idempotent:, &)
        def product_version = ::Wurk::VERSION
        def number_with_delimiter(num) = num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse

        # The "<score>-<jid>" key an extension round-trips through a URL or form.
        def job_params(job, score) = "#{score}-#{job['jid']}"

        def parse_key(key)
          score, jid = key.to_s.split('-', 2)
          [score.to_f, jid]
        end
        alias parse_params parse_key

        # The current safe query params with `options` over them.
        def qparams(options)
          current = params.to_h.transform_keys(&:to_s)
          to_query_string(current.merge(options.transform_keys(&:to_s)))
        end

        def to_query_string(pairs)
          pairs.filter_map do |key, value|
            "#{key}=#{::CGI.escape(value.to_s)}" if SAFE_QPARAMS.include?(key.to_s)
          end.join('&')
        end

        # Back to `location` keeping the query of the page the form was posted from.
        def redirect_with_query(location)
          query = ::URI.parse(request.referer.to_s).query
          redirect(query.to_s.empty? ? location : "#{location}?#{query}")
        rescue ::URI::InvalidURIError
          redirect(location)
        end

        def filtering(which)
          action = "#{root_path}filter/#{h(which)}"
          input = %(<input class="search-query" type="search" name="substr" value="#{h(url_params('substr'))}">)
          %(<form method="post" class="form-inline" action="#{action}">#{csrf_tag}#{input}</form>)
        end

        def text_direction = 'ltr'
        def rtl? = false
        def locale = 'en'
        def stats = (@stats ||= ::Wurk::Stats.new)
        def workset = ::Wurk::WorkSet.new
        def processes = ::Wurk::ProcessSet.new
        def sorted_processes = processes.to_a.sort_by { |process| process['identity'] }

        private

        def humanize_key(key)
          return key.tr('_', ' ').capitalize unless key.match?(/\A[A-Z]/)

          key.gsub(/(?<=[a-z])(?=[A-Z])/, ' ')
        end
      end
    end
  end
end
