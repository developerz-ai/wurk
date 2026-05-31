# frozen_string_literal: true

require_relative 'points'

module Wurk
  module Limiter
    # No-op for the tests + bypass scenarios documented in §1.8. The
    # within_limit block runs unconditionally and the introspection
    # methods all return zeros so dashboards render predictably.
    class Unlimited
      def name = 'unlimited'
      def type = :unlimited
      def options = {}
      def size = 0
      def fingerprint = Digest::SHA256.hexdigest('unlimited')
      def reset = nil
      def delete = nil

      # Uniform status shape (#16): no limit, always available.
      def status
        { used: 0, limit: nil, reset_at: nil, available?: true }
      end

      # Accept all the kwargs the other limiters take so a worker can swap
      # `limiter = Sidekiq::Limiter.unlimited` in tests without touching
      # call sites. `points`-style callers pass an `estimate:` and expect a
      # `|handle|` block param — we yield a zero-cost handle just in case.
      def within_limit(**_kwargs, &block)
        raise ArgumentError, 'block required' unless block

        if block.arity.zero?
          block.call
        else
          block.call(Points::Handle.new(self, 0))
        end
      end
    end
  end
end
