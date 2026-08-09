# frozen_string_literal: true

require_relative '../api'
require_relative 'problem'

module Wurk
  module API
    # Whether this deployment answers anything but reads.
    #
    # The dashboard has had a read-only mode since the beginning
    # (`Wurk::Web.config.read_only`, `WURK_WEB_READ_ONLY=1`): a viewer-only
    # deploy — the public demo is one — where every non-safe verb 403s. The
    # machine plane keeps exactly that rule, verb for verb, so "read-only"
    # means one thing across Wurk instead of two. That freezes `admin`'s
    # destructive routes and `enqueue` alike: a deployment an operator may not
    # retry a job on is not one a stranger should be able to start a thousand
    # on, and the alternative is a word whose meaning depends on which plane
    # you are standing in.
    #
    # Only the *mount* differs, and it has to — see `Configuration#api_read_only`
    # for the three states. Nested in the engine, this API is part of the
    # dashboard's deployment and inherits its flag through the Rack env
    # (`Wurk::Web::Authorization` stamps {Wurk::API::READ_ONLY_ENV}). Mounted on
    # its own path or run standalone it is a different deployment, has no engine
    # in front of it to stamp anything, and says so itself or not at all.
    module ReadOnly
      # RFC 9110 §9.2.1 — the verbs with no side effects the client asked for.
      # The same three the dashboard's Authorization middleware allows; the API
      # registers no OPTIONS route, but a read-only deploy refusing a preflight
      # would be a lie about why.
      SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

      module_function

      # An explicit setting wins both ways — `false` is how a host keeps its
      # producer live under a read-only dashboard, so it has to outrank what the
      # engine stamped, not merely be OR'd into it.
      #
      # @return [Boolean] whether writes are frozen for this request's mount.
      def enabled?(request)
        explicit = request.config.api_read_only
        return explicit unless explicit.nil?

        inherited?(request) || request.config.api_read_only?
      end

      # @return [Array, nil] a 403 problem triple, or nil to let the request on.
      def refuse(request)
        return nil if SAFE_METHODS.include?(request.request_method)
        return nil unless enabled?(request)

        Problem.render(
          Problem::READ_ONLY,
          status: 403,
          detail: 'This Wurk deployment is read-only; it answers GET and HEAD only.',
          instance: request.path
        )
      end

      # Checked before routing, so a write to a path that does not exist is
      # refused for the reason that applies to every write here rather than
      # 404ing and leaving a client to discover the freeze one route later.
      def inherited?(request)
        !!request.get_header(::Wurk::API::READ_ONLY_ENV)
      end
    end
  end
end
