# frozen_string_literal: true

require_relative '../limiter'
require_relative 'problem'

module Wurk
  module API
    # Per-token request ceiling for the HTTP API.
    #
    # A {Wurk::Limiter::Window} per credential, not a second limiter: Wurk
    # already owns a sliding window whose trim-count-add step is one atomic Lua
    # call timed off the Redis clock, so a fleet of web processes shares one
    # verdict and a producer's own clock cannot argue with it. Reusing it also
    # means an API ceiling is a limiter like any other — it registers into
    # `lmtr-list`, and `GET /v1/limiters` and the dashboard's Limiters page show
    # it beside the ones the jobs use.
    #
    # The window is named for the token's fingerprint (a truncated,
    # domain-separated digest — {Auth#fingerprint}), never the token: the name
    # is a Redis key and shows up in the dashboard.
    #
    # Off unless `config.api_rate_limit` is set, and then it is exactly one
    # extra round trip per request. Nothing here rescues a Redis failure: a
    # window that cannot be read cannot limit, and an API that quietly drops
    # its ceiling the moment Redis is in trouble sheds it precisely when the
    # load matters. The error surfaces as App's 500, which a client retries.
    module Throttle
      NAME_PREFIX = 'api-token:'

      # No waiting. `within_limit` sleeps until a slot frees, which is right for
      # a worker thread and wrong for a socket a client is holding open — an
      # over-limit request has an answer already (429 + Retry-After), and it is
      # cheaper for both ends than a held connection.
      NO_WAIT = 0

      # Retry-After is a whole number of seconds (RFC 9110 §10.2.3) and must
      # never be 0: a client that reads "wait 0" retries immediately, which is
      # what got it throttled.
      MIN_RETRY_AFTER = 1

      LOCK = Mutex.new

      module_function

      # @return [Array, nil] a 429 problem triple, or nil when the request may
      #   proceed (including when no limit is configured).
      def refuse(request)
        limit = request.config.api_rate_limit
        return nil unless limit

        interval = request.config.api_rate_limit_interval
        limiter = for_principal(request.principal, limit, interval)
        limiter.within_limit { nil }
      rescue ::Wurk::Limiter::OverLimit => e
        over_limit(request, e.limiter, limit, interval)
      end

      # Limiters are stateless Ruby objects — every operation is a Lua call — so
      # one per (credential, ceiling) is safe to keep and share across threads
      # and across a fork. Kept because constructing one writes its metadata
      # hash, and paying that round trip per request would double the cost of
      # the feature. Keyed by the ceiling too, so a host that changes it gets a
      # limiter that agrees with the config rather than the one built first.
      def for_principal(principal, limit, interval)
        key = [principal.id, limit, interval]
        found = LOCK.synchronize { cache[key] }
        return found if found

        # Built outside the lock: registration is a Redis round trip, and a
        # racing second build only rewrites the same metadata hash.
        built = ::Wurk::Limiter.window("#{NAME_PREFIX}#{principal.id}", limit, interval, wait_timeout: NO_WAIT)
        LOCK.synchronize { cache[key] ||= built }
      end

      def cache
        @cache ||= {}
      end

      # `reset_at` is when the window's oldest entry slides out — the first
      # moment a slot exists — read fresh rather than guessed from the interval,
      # which would tell a client that trickled up to the ceiling to wait a full
      # window for a slot that frees in a second. One extra read, on the refused
      # path only.
      def retry_after(limiter, interval)
        reset_at = limiter.status[:reset_at]
        seconds = reset_at ? (reset_at - ::Time.now.to_f).ceil : interval_seconds(interval)
        [seconds, MIN_RETRY_AFTER].max
      end

      def interval_seconds(interval)
        ::Wurk::Limiter.interval_seconds(interval, allow_integer: true)
      end

      def over_limit(request, limiter, limit, interval)
        seconds = retry_after(limiter, interval)
        Problem.render(
          Problem::RATE_LIMITED,
          status: 429,
          detail: "This token is limited to #{limit} requests per #{interval}.",
          instance: request.path,
          headers: { 'retry-after' => seconds.to_s },
          limit: limit,
          interval_seconds: interval_seconds(interval),
          retry_after: seconds
        )
      end
    end
  end
end
